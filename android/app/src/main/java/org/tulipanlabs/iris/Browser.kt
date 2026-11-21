package org.tulipanlabs.iris

import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import com.cefrium.Cefrium
import com.cefrium.CefriumBrowser
import com.cefrium.CefriumChromeClient
import com.cefrium.CefriumContextMenu
import com.cefrium.CefriumFileChooserCallback
import com.cefrium.CefriumFileChooserParams
import com.cefrium.CefriumLoadError
import com.cefrium.CefriumNavigationClient
import com.cefrium.CefriumNavigationRequest
import com.cefrium.CefriumProfile
import com.cefrium.CefriumRendererTerminationStatus
import com.cefrium.CefriumResourceInterceptor
import java.util.UUID

/**
 * A page: one Chromium browser (Cefrium, Chromium built into Iris) drawn
 * into a view, the same engine whatever the phone's WebView is.
 */
class Page(ctx: Context, val b: CefriumBrowser) : FrameLayout(ctx) {
    init {
        addView(b.surfaceContainer, LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
    }

    fun goBack() = b.goBack()
    fun goForward() = b.goForward()
    fun reload() = b.reload()
    fun stopLoading() = b.stopLoading()
    fun loadUrl(u: String) = b.loadUrl(u)
    fun onPause() = b.onPause()
    fun onResume() = b.onResume()
    fun destroy() = b.close()
    val url: String get() = b.url ?: ""

    /** the back and forward history, kept while the page sleeps */
    fun saveState(out: Bundle) {
        runCatching { b.serializeNavigationState()?.let { out.putByteArray("nav", it) } }
        out.putString("url", b.url ?: "")
    }

    fun restoreState(s: Bundle): Boolean {
        val nav = s.getByteArray("nav") ?: return false
        return runCatching { b.restoreNavigationState(nav); true }.getOrDefault(false)
    }

    /** pages in the look's colours, where the engine offers it */
    fun dark(on: Boolean) {
        runCatching { b.javaClass.getMethod("setDarkMode", Boolean::class.javaPrimitiveType).invoke(b, on) }
    }
}

/**
 * One tab: a page in its container's profile (cookies, storage and cache of
 * its own), made when the tab first opens something, so a new or restored
 * tab costs nothing until you go to it.
 */
class Tab(val container: String?, url: String = "") {
    val id: String = UUID.randomUUID().toString()
    var url by mutableStateOf(url)
    var title by mutableStateOf("")
    var progress by mutableIntStateOf(0)
    var loading by mutableStateOf(false)
    var canBack by mutableStateOf(false)
    var canForward by mutableStateOf(false)
    var web by mutableStateOf<Page?>(null)
    /** ads and trackers stopped on this page */
    var blocked by mutableIntStateOf(0)
    /** an address to open when the tab is next shown */
    var pending: String? = null
    /** the page's history, kept while the tab sleeps */
    var saved: Bundle? = null
    var lastShown = System.currentTimeMillis()
    var crashed by mutableStateOf(false)

    val isPrivate get() = container == Container.PRIVATE

    fun back() { web?.goBack() }
    fun forward() { web?.goForward() }
    fun reload() { web?.reload() }
    fun stop() { web?.stopLoading() }
}

/** a pop-up the page asked for and Iris stopped */
data class Blocked(val url: String, val from: Tab)

/** what a long press on a page landed on */
data class Pressed(val tab: Tab, val link: String?, val image: String?)

/**
 * The tabs and their pages, kept here so they outlive Compose's
 * recompositions.
 */
class BrowserModel(app: Application) : AndroidViewModel(app) {
    val tabs = mutableStateListOf<Tab>()
    var current by mutableStateOf<Tab?>(null)
        private set
    var blocked by mutableStateOf<Blocked?>(null)
    var pressed by mutableStateOf<Pressed?>(null)
    /** a video in full screen: the bars step aside */
    var fullscreen by mutableStateOf(false)
    /** the activity pages are drawn in (Chromium's surfaces need one) */
    var activity: Activity? = null
    private val closed = ArrayDeque<Pair<String, String?>>()
    private val ui = Handler(Looper.getMainLooper())
    private val ctx: Context get() = getApplication()
    /** pages in dark colours (the look) */
    var dark = false
        set(v) { field = v; tabs.forEach { it.web?.dark(v) } }

    val containersWork = true

    init {
        Store.tabs.forEach { s ->
            val c = if (s.container == null || Store.container(s.container) != null) s.container else null
            tabs.add(Tab(c).also { it.pending = s.url; it.title = s.title; it.url = s.url })
        }
        if (tabs.isEmpty()) newTab() else select(tabs[Store.selected.coerceIn(0, tabs.size - 1)])
        Shields.changed = { css.clear() }
    }

    fun newTab(url: String? = null, container: String? = null, after: Tab? = null, select: Boolean = true): Tab {
        val t = Tab(container)
        val i = after?.let { tabs.indexOf(it) } ?: -1
        if (i >= 0) tabs.add(i + 1, t) else tabs.add(t)
        if (!url.isNullOrEmpty()) {
            t.url = url
            if (select) load(t, url) else t.pending = url
        }
        if (select || current == null) select(t)
        save()
        return t
    }

    fun select(t: Tab) {
        current?.let { it.lastShown = System.currentTimeMillis(); it.web?.onPause() }
        current = t
        t.lastShown = System.currentTimeMillis()
        t.pending?.let { p -> if (activity != null) { t.pending = null; load(t, p) } }
        t.web?.onResume()
        Store.selected = tabs.indexOf(t)
        sleepIdle()
    }

    /** the activity is here: the shown tab opens what it was waiting for */
    fun attached(a: Activity) {
        activity = a
        current?.let { t -> t.pending?.let { p -> t.pending = null; load(t, p) } }
    }

    /** Closing a tab never closes Iris: the one beside it takes its place,
     *  and closing the last one leaves a fresh tab. */
    fun close(t: Tab) {
        val i = tabs.indexOf(t)
        if (i < 0) return
        if (t.url.isNotEmpty() && !t.isPrivate) closed.addLast(t.url to t.container)
        tabs.removeAt(i)
        destroy(t)
        if (current === t) {
            current = null
            if (tabs.isEmpty()) newTab() else select(tabs[minOf(i, tabs.size - 1)])
        }
        if (t.isPrivate && tabs.none { it.isPrivate }) clearPrivate()
        save()
    }

    fun reopenClosed() {
        val (u, c) = closed.removeLastOrNull() ?: return
        newTab(u, c)
    }

    fun go(text: String) {
        val u = Search.resolve(text)
        if (u.isEmpty()) return
        val t = current ?: newTab()
        load(t, u)
    }

    fun load(t: Tab, url: String) {
        t.url = url
        t.crashed = false
        val w = web(t) ?: run { t.pending = url; return }
        val s = t.saved
        if (s != null) {
            t.saved = null
            if (!w.restoreState(s)) w.loadUrl(url)
        } else {
            w.loadUrl(url)
        }
        save()
    }

    /** back to the new-tab page in this tab */
    fun home(t: Tab) {
        destroy(t)
        t.url = ""
        t.title = ""
        t.canBack = false
        t.canForward = false
        save()
    }

    /** Tabs left alone give their memory back: beyond 3 awake background
     *  tabs, the longest unseen sleep (their history kept). */
    private fun sleepIdle() {
        val awake = tabs.filter { it !== current && it.web != null }.sortedByDescending { it.lastShown }
        awake.drop(3).forEach { t ->
            val b = Bundle()
            t.web?.saveState(b)
            t.saved = b
            t.pending = t.url.ifEmpty { null }
            destroy(t)
        }
    }

    private fun destroy(t: Tab) {
        t.web?.let { w ->
            (w.parent as? ViewGroup)?.removeView(w)
            runCatching { w.stopLoading() }
            runCatching { w.destroy() }
        }
        t.web = null
    }

    // ---- profiles: containers and private tabs ----

    private fun profileOf(t: Tab): CefriumProfile = when {
        t.isPrivate -> CefriumProfile.incognito()
        t.container != null -> CefriumProfile.get("c-" + t.container.lowercase().map { if (it.isLetterOrDigit()) it else '_' }.joinToString("").take(60))
        else -> CefriumProfile.getDefault()
    }

    private fun clear(p: CefriumProfile) {
        runCatching { p.cookieManager.removeAllCookies {} }
        runCatching { p.listSiteData { sites -> for (d in sites) p.clearSiteData(d.site, null) } }
    }

    /** the private tabs' profile is wiped when the last one closes */
    private fun clearPrivate() = runCatching { clear(CefriumProfile.incognito()) }

    /** a container's tabs close and everything its sites kept goes */
    fun removeContainer(id: String) {
        tabs.filter { it.container == id }.forEach(::close)
        runCatching { clear(CefriumProfile.get("c-" + id.lowercase().map { if (it.isLetterOrDigit()) it else '_' }.joinToString("").take(60))) }
    }

    fun shieldsFor(url: String) = Shields.onFor(url)

    fun toggleSiteShields(t: Tab) {
        val h = Search.host(t.url) ?: return
        val site = Search.site(h)
        val off = Store.shieldsOff.toMutableSet()
        if (!off.add(site)) off.remove(site)
        Store.shieldsOff = off
        css.clear()
        t.reload()
    }

    fun shieldsChanged() {
        css.clear()
        current?.reload()
    }

    // ---- the engine ----

    private val youtube by lazy { runCatching { ctx.assets.open("js/youtube.js").bufferedReader().use { it.readText() } }.getOrDefault("") }

    /** the tab's page, made on first use (null until the activity is here) */
    fun web(t: Tab, popup: CefriumBrowser? = null): Page? {
        t.web?.let { return it }
        val act = activity ?: return null
        val b = popup ?: CefriumBrowser.createWithSurface(act, profileOf(t))
        val w = Page(act, b)
        b.setPinchToZoomEnabled(true)
        b.setPullToRefreshEnabled(true)
        if (youtube.isNotBlank()) runCatching { b.addDocumentStartJavaScript(youtube, setOf("*")) }
        b.setResourceInterceptor(Shield(t))
        b.setNavigationClient(Nav(t, w))
        b.setChromeClient(Chrome(t))
        b.setDownloadHandler(Downloader(t))
        w.dark(dark)
        t.web = w
        if (t !== current) w.onPause()
        return w
    }

    /** what a request is, for the filter lists: the engine says, the address helps */
    private fun kindOf(r: CefriumBrowser.ResourceRequest): Int {
        val type = runCatching { r.type?.name ?: "" }.getOrDefault("")
        when (type) {
            "STYLESHEET" -> return Kind.STYLESHEET
            "FONT" -> return Kind.FONT
            "SCRIPT" -> return Kind.SCRIPT
            "IMAGE", "FAVICON" -> return Kind.IMAGE
            "MEDIA" -> return Kind.MEDIA
            "XHR" -> return Kind.XHR
            "SUB_FRAME" -> return Kind.SUBDOCUMENT
            "PING" -> return Kind.PING
        }
        val p = (Uri.parse(r.url ?: "").path ?: "").lowercase()
        return when {
            p.endsWith(".css") -> Kind.STYLESHEET
            p.endsWith(".woff") || p.endsWith(".woff2") || p.endsWith(".ttf") || p.endsWith(".otf") -> Kind.FONT
            p.endsWith(".js") || p.endsWith(".mjs") -> Kind.SCRIPT
            listOf(".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".avif", ".ico").any { p.endsWith(it) } -> Kind.IMAGE
            listOf(".mp4", ".webm", ".m3u8", ".mp3", ".m4s").any { p.endsWith(it) } -> Kind.MEDIA
            else -> Kind.OTHER
        }
    }

    /** Iris Shields: Chromium asks before every request, on its network
     *  thread; what is stopped never leaves the phone */
    private inner class Shield(private val t: Tab) : CefriumResourceInterceptor {
        override fun shouldBlockRequest(r: CefriumBrowser.ResourceRequest): Boolean {
            val u = r.url ?: return false
            val page = (r.topLevelUrl ?: "").ifEmpty { t.url }
            val block = Shields.core.blocks(u, page, kindOf(r), r.isMainFrame)
            if (block) ui.post { t.blocked++ }
            return block
        }
    }

    /** the style sheet hiding what ads leave on each site, kept for a few sites */
    private val css = object : LinkedHashMap<String, String>(32, 0.75f, true) {
        override fun removeEldestEntry(e: MutableMap.MutableEntry<String, String>?) = size > 24
    }

    private fun hide(w: Page, page: String) {
        if (!page.startsWith("http")) return
        val host = hostOf(page)
        val sheet = synchronized(css) { css[host] ?: Shields.core.hidingCSS(page).also { css[host] = it } }
        if (sheet.isEmpty()) return
        val js = "(() => { const add = () => { let s = document.getElementById('iris-shields'); if (!s) { s = document.createElement('style'); " +
            "s.id = 'iris-shields'; (document.head || document.documentElement).appendChild(s); } if (!s.textContent) s.textContent = " +
            org.json.JSONObject.quote(sheet) + "; }; if (document.documentElement) add(); else document.addEventListener('DOMContentLoaded', add); })();"
        runCatching { w.b.evaluateJavaScript(js) }
    }

    private inner class Nav(private val t: Tab, private val w: Page) : CefriumNavigationClient {
        override fun onBeforeNavigate(browser: CefriumBrowser, request: CefriumNavigationRequest): Boolean {
            val u = request.url ?: return false
            val s = u.lowercase()
            if (s.startsWith("http:") || s.startsWith("https:") || s.startsWith("about:") || s.startsWith("data:") || s.startsWith("blob:")) return false
            // another app's link (intent:, tel:, mailto:, market:): only from a
            // tap, so a page cannot open apps by itself
            if (!request.hasGesture()) return true
            try {
                val i = if (s.startsWith("intent:")) Intent.parseUri(u, Intent.URI_INTENT_SCHEME) else Intent(Intent.ACTION_VIEW, Uri.parse(u))
                i.addCategory(Intent.CATEGORY_BROWSABLE)
                i.component = null
                i.selector = null
                // an intent: link may not grant access to Iris's own files
                i.flags = i.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION).inv()
                i.clipData = null
                i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                ctx.startActivity(i)
            } catch (e: Exception) {
                // an intent: link with a web fallback opens that instead
                if (s.startsWith("intent:")) {
                    Regex("S\\.browser_fallback_url=([^;]+)").find(u)?.groupValues?.get(1)?.let { fb -> ui.post { w.loadUrl(Uri.decode(fb)) } }
                }
            }
            return true
        }

        override fun onLoadStart(browser: CefriumBrowser, url: String) {
            t.url = url
            t.blocked = 0
            t.loading = true
            t.progress = 5
        }

        override fun onUrlChanged(browser: CefriumBrowser, url: String) {
            t.url = url
        }

        override fun onDocumentAvailable(browser: CefriumBrowser) = hide(w, t.url)

        override fun onProgressChanged(browser: CefriumBrowser, percent: Int) {
            t.progress = percent
        }

        override fun onLoadingStateChanged(browser: CefriumBrowser, loading: Boolean, canGoBack: Boolean, canGoForward: Boolean) {
            t.canBack = canGoBack
            t.canForward = canGoForward
            t.loading = loading
            if (!loading) {
                hide(w, t.url)
                t.progress = 100
                if (!t.isPrivate) Store.visit(t.url, t.title)
                save()
            }
        }

        override fun onLoadError(browser: CefriumBrowser, error: CefriumLoadError) {}

        override fun onRenderProcessTerminated(browser: CefriumBrowser, status: CefriumRendererTerminationStatus, errorCode: Int) {
            // the page's process ended (memory or a crash): the tab gets a
            // fresh page and opens its address again when shown
            ui.post {
                destroy(t)
                t.pending = t.url.ifEmpty { null }
                t.crashed = true
                if (t === current) t.pending?.let { p -> t.pending = null; load(t, p) }
            }
        }
    }

    private inner class Chrome(private val t: Tab) : CefriumChromeClient {
        override fun onTitleChanged(browser: CefriumBrowser, title: String?) { t.title = title ?: "" }

        override fun onFullscreenChanged(browser: CefriumBrowser, fullscreen: Boolean) {
            if (t === current) this@BrowserModel.fullscreen = fullscreen
        }

        // pop-ups: only from a tap; ads open no tabs
        override fun onCreateWindow(browser: CefriumBrowser, popup: CefriumBrowser, url: String?, userGesture: Boolean): Boolean {
            if (!userGesture) return false
            val u = url ?: ""
            if (u.startsWith("http") && !popupAllowed(t, u)) {
                ui.post { blocked = Blocked(u, t) }
                return false
            }
            val nt = Tab(t.container, u)
            tabs.add(tabs.indexOf(t) + 1, nt)
            web(nt, popup)
            select(nt)
            save()
            return true
        }

        override fun onCloseWindow(browser: CefriumBrowser, popup: CefriumBrowser) {
            ui.post { tabs.firstOrNull { it.web?.b === popup }?.let(::close) }
        }

        override fun onContextMenu(browser: CefriumBrowser, menu: CefriumContextMenu): Boolean {
            val link = menu.linkUrl ?: ""
            val image = menu.sourceUrl ?: ""
            if (link.isEmpty() && image.isEmpty()) return false // text: the engine's own selection menu
            menu.cancel()
            ui.post { pressed = Pressed(t, link.ifEmpty { null }, image.ifEmpty { null }) }
            return true
        }

        // the engine's own file chooser and permission prompts (camera,
        // microphone and location stay off unless the person allows them)
        override fun onShowFileChooser(browser: CefriumBrowser, params: CefriumFileChooserParams, callback: CefriumFileChooserCallback): Boolean = false
    }

    /** downloads go to the phone's Downloads folder, with the page's cookies */
    private inner class Downloader(private val t: Tab) : CefriumBrowser.CefriumDownloadHandler {
        override fun onBeforeDownload(item: CefriumBrowser.DownloadItem, callback: CefriumBrowser.BeforeDownloadCallback) {
            val u = item.url ?: ""
            if (!u.startsWith("http")) {
                callback.allow(null) // a file the page made (blob:, data:): saved by the engine
                return
            }
            callback.cancel()
            val p = profileOf(t)
            runCatching {
                p.cookieManager.getCookie(u) { c ->
                    ui.post { Downloads.fetch(ctx, u, Pages.mobileAgent(), null, item.mimeType, -1, c, t.url, item.suggestedName) }
                }
            }.onFailure { Downloads.fetch(ctx, u, Pages.mobileAgent(), null, item.mimeType, -1, null, t.url, item.suggestedName) }
        }

        override fun onDownloadUpdated(item: CefriumBrowser.DownloadItem) {}
    }

    /** a tapped pop-up opens as a tab, unless it goes to an ad or tracker */
    fun popupAllowed(from: Tab, url: String): Boolean {
        val host = Search.host(url) ?: return false
        return !(Shields.onFor(from.url) && Shields.isBlocked(host))
    }

    fun save() {
        Store.tabs = tabs.filter { !it.isPrivate && (it.pending ?: it.url).isNotEmpty() }
            .map { SavedTab(it.pending ?: it.url, it.title, it.container) }
        current?.let { Store.selected = tabs.indexOf(it) }
    }

    override fun onCleared() {
        save()
        tabs.forEach(::destroy)
    }
}

/** the engine's names, for the about line and the user agent */
object Pages {
    private val major get() = runCatching { Cefrium.getChromiumVersion().substringBefore('.') }.getOrDefault("150")
    fun engine() = runCatching { "Chromium ${Cefrium.getChromiumVersion()} (Cefrium ${Cefrium.getVersion()})" }.getOrDefault("Chromium")
    fun mobileAgent() = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/$major.0.0.0 Mobile Safari/537.36"
}
