// SPDX-License-Identifier: GPL-3.0-only
package org.tulipanlabs.lite

import android.app.Activity
import android.app.DownloadManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.view.ViewGroup
import android.widget.FrameLayout
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
import java.security.SecureRandom

// A tab and its page. Iris carries its own Chromium (CEF, through Cefrium), the
// same engine as Iris on the computer, with Iris Shields between the page and
// the network.

class Tab(val id: Long, val private: Boolean, val container: String = "") {
    var url = ""
    /** the search shown on Iris's own results page, while it is open */
    var lite = ""
    var title = ""
    var web: Page? = null
    var saved: Bundle? = null // the page's history while its browser is put away to save memory
    var progress = 100
    var blocked = 0
    var lastUsed = 0L
    var canBack = false
    var canForward = false
    @Volatile var page = "" // the page's address, for the shield (read on the network thread)
}

/** What the pages tell the browser (all on the UI thread). */
interface PageEvents {
    fun onUrl(t: Tab, url: String)
    fun onTitle(t: Tab, title: String)
    fun onProgress(t: Tab, progress: Int)
    fun onBlocked(t: Tab)
    fun onNewTab(from: Tab, url: String, popup: CefriumBrowser?)
    fun onClosePopup(popup: CefriumBrowser)
    fun onFullscreen(t: Tab, on: Boolean)
    fun onCrashed(t: Tab)
    fun onLongPress(t: Tab, link: String, image: String)
}

/**
 * A page: one Chromium browser drawn into a view. It answers the few calls
 * the rest of the app makes the way Android's WebView did (back, forward,
 * reload, scripts with a result, history kept while the page sleeps).
 */
class Page(ctx: Context, val b: CefriumBrowser) : FrameLayout(ctx) {
    private val ui = Handler(Looper.getMainLooper())
    private val pending = HashMap<Int, (String?) -> Unit>()
    private var next = SecureRandom().nextInt(1 shl 20) // tokens a page cannot guess
    var back = false
    var forward = false
    /** called when a load ends (the WebView's onPageFinished), for the results reader */
    var onFinished: ((String) -> Unit)? = null

    init {
        addView(b.surfaceContainer, LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
    }

    /**
     * Lets scripts answer: their value comes back through window.cefriumQuery,
     * which only pages whose address passes allow may call (the results
     * reader allows Google alone; tabs never get it).
     */
    fun answers(allow: (String) -> Boolean) {
        val policy = object : CefriumBrowser.QueryOriginPolicy {
            override fun allows(frameUrl: String?): Boolean = allow(frameUrl ?: "")
        }
        val handler = object : CefriumBrowser.QueryHandler {
            override fun onQuery(queryId: Long, request: String?, origin: String?, callback: CefriumBrowser.QueryCallback?): Boolean {
                callback?.success("")
                val req = request ?: return true
                val i = req.indexOf(",\"v\":")
                val tok = if (i > 5) req.substring(5, i).toIntOrNull() else null
                val raw = if (i > 0) req.substring(i + 5, req.length - 1) else null
                ui.post { tok?.let { pending.remove(it) }?.invoke(raw) }
                return true
            }
        }
        b.setQueryHandler(policy, handler)
    }

    fun canGoBack() = back || b.canGoBack()
    fun canGoForward() = forward
    fun goBack() = b.goBack()
    fun goForward() = b.goForward()
    fun reload() = b.reload()
    fun stopLoading() = b.stopLoading()
    fun loadUrl(u: String) = b.loadUrl(u)
    fun loadDataWithBaseURL(base: String, data: String, mime: String, enc: String, history: String) =
        b.loadDataWithBaseUrl(base, data, mime, enc, history)
    fun onPause() = b.onPause()
    fun onResume() = b.onResume()
    fun clearCache() = b.clearCache()
    fun destroy() {
        pending.clear()
        b.close()
    }

    /** runs js; when cb is given, js is an expression and cb gets its value as JSON (as WebView's evaluateJavascript) */
    fun evaluateJavascript(js: String, cb: ((String?) -> Unit)?) {
        if (cb == null) {
            b.evaluateJavaScript(js)
            return
        }
        val tok = ++next
        pending[tok] = cb
        b.evaluateJavaScript("(function(){var r=null;try{r=(" + js + "\n);}catch(e){}" +
            "if(r===undefined)r=null;try{window.cefriumQuery({request:'{\"t\":" + tok + ",\"v\":'+JSON.stringify(r)+'}'," +
            "onSuccess:function(){},onFailure:function(){}});}catch(e){}})();")
    }

    /** the back and forward history, kept while the page sleeps */
    fun saveState(out: Bundle) {
        try { b.serializeNavigationState()?.let { out.putByteArray("nav", it) } } catch (e: Exception) {}
        out.putString("url", b.url ?: "")
    }

    /** puts saved history back; null when there was none to put back */
    fun restoreState(s: Bundle): Any? {
        val nav = s.getByteArray("nav") ?: return null
        return try { b.restoreNavigationState(nav); this } catch (e: Exception) { null }
    }

    fun desktop(on: Boolean) = b.setUserAgentOverride(if (on) Pages.desktopAgent() else Pages.mobileAgent())
}

class Pages(private val act: Activity, private val set: Settings, private val events: PageEvents) {
    private val ctx: Context = act
    private val ui = Handler(Looper.getMainLooper())
    @Volatile var shields: Shields? = null
    private val seed = SecureRandom().nextInt().toLong() and 0xffffffffL
    private val upgraded = HashSet<String>() // hosts tried over https by HTTPS-only
    private val insecureOK = HashSet<String>()
    private val cssCache = object : LinkedHashMap<String, String>(32, 0.75f, true) {
        override fun removeEldestEntry(e: MutableMap.MutableEntry<String, String>?) = size > 24
    }

    private fun asset(name: String): String = try {
        ctx.assets.open("js/$name").bufferedReader().use { it.readText() }
    } catch (e: Exception) {
        ""
    }

    /** the scripts that run before a page's own: fingerprinting protection, YouTube without ads, lighter YouTube */
    private fun scripts(): List<String> {
        val out = ArrayList<String>()
        if (set.shields && set.farble) out.add(asset("farble.js").replace("SEED", seed.toString()))
        if (set.shields && set.youtube) out.add(asset("youtube.js"))
        if (set.youtubeLight) out.add(asset("youtube-light.js"))
        return out.filter { it.isNotBlank() }
    }

    /** every container keeps its own sign-ins: the engine has profiles */
    val containersWork = true

    private fun profileOf(t: Tab): CefriumProfile = when {
        t.private -> CefriumProfile.incognito()
        t.container.isNotEmpty() -> CefriumProfile.get("c-" + t.container.lowercase().map { if (it.isLetterOrDigit()) it else '_' }.joinToString("").take(60))
        else -> CefriumProfile.getDefault()
    }

    /** a page for tab t; popup is a window a page opened, already loading */
    fun make(t: Tab, popup: CefriumBrowser? = null): Page {
        val b = popup ?: CefriumBrowser.createWithSurface(act, profileOf(t))
        val w = Page(ctx, b)
        t.web = w
        if (set.desktop) w.desktop(true)
        b.setPinchToZoomEnabled(true)
        b.setPullToRefreshEnabled(false)
        for (js in scripts()) {
            try { b.addDocumentStartJavaScript(js, setOf("*")) } catch (e: Exception) {}
        }
        b.setResourceInterceptor(Shield(t))
        b.setNavigationClient(Nav(t, w))
        b.setChromeClient(Chrome(t))
        b.setDownloadHandler(Downloads())
        return w
    }

    /** a plain page with no tab, for reading Google's results off screen */
    fun plain(): Page {
        val w = Page(ctx, CefriumBrowser.createWithSurface(act, CefriumProfile.getDefault()))
        w.answers { u -> hostOf(u).let { it == "google.com" || it.endsWith(".google.com") } }
        w.b.setNavigationClient(object : CefriumNavigationClient {
            override fun onLoadingStateChanged(browser: CefriumBrowser, loading: Boolean, canGoBack: Boolean, canGoForward: Boolean) {
                if (!loading) w.onFinished?.invoke(browser.url ?: "")
            }
        })
        return w
    }

    fun shieldOn(page: String): Boolean = set.shields && hostOf(page).removePrefix("www.") !in set.shieldOff

    /** The style sheet that hides what ads leave behind on this page. */
    fun hide(w: Page, page: String) {
        if (!shieldOn(page) || !page.startsWith("http")) return
        val e = shields ?: return
        val host = hostOf(page)
        val css = synchronized(cssCache) { cssCache[host] ?: e.hidingCSS(page).also { cssCache[host] = it } }
        if (css.isEmpty()) return
        val js = "(() => { const add = () => { let s = document.getElementById('lite-shields'); if (!s) { s = document.createElement('style'); " +
            "s.id = 'lite-shields'; (document.head || document.documentElement).appendChild(s); } if (!s.textContent) s.textContent = " +
            org.json.JSONObject.quote(css) + "; }; if (document.documentElement) add(); else document.addEventListener('DOMContentLoaded', add); })();"
        w.evaluateJavascript(js, null)
    }

    fun clearCache() = synchronized(cssCache) { cssCache.clear() }

    /** what a request is, for the filter lists: the engine says, the address helps */
    private fun kindOf(r: CefriumBrowser.ResourceRequest): Int {
        val type = try { r.type?.name ?: "" } catch (e: Throwable) { "" }
        when (type) {
            "STYLESHEET" -> return Kind.STYLESHEET
            "FONT" -> return Kind.FONT
            "SCRIPT" -> return Kind.SCRIPT
            "IMAGE", "FAVICON" -> return Kind.IMAGE
            "MEDIA" -> return Kind.MEDIA
            "XHR" -> return Kind.XHR
            "SUB_FRAME" -> return Kind.SUBDOCUMENT
        }
        val p = (Uri.parse(r.url).path ?: "").lowercase()
        return when {
            p.endsWith(".css") -> Kind.STYLESHEET
            p.endsWith(".woff") || p.endsWith(".woff2") || p.endsWith(".ttf") || p.endsWith(".otf") -> Kind.FONT
            p.endsWith(".js") || p.endsWith(".mjs") -> Kind.SCRIPT
            listOf(".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".avif", ".ico").any { p.endsWith(it) } -> Kind.IMAGE
            listOf(".mp4", ".webm", ".m3u8", ".mp3", ".m4s").any { p.endsWith(it) } -> Kind.MEDIA
            else -> Kind.OTHER
        }
    }

    /** Iris Shields: ads and trackers never leave the phone (runs on the network thread) */
    inner class Shield(private val t: Tab) : CefriumResourceInterceptor {
        override fun shouldBlockRequest(r: CefriumBrowser.ResourceRequest): Boolean {
            if (r.isMainFrame) return false
            val u = r.url ?: return false
            if (!u.startsWith("http")) return false
            val page = (r.topLevelUrl ?: "").ifEmpty { t.page }
            if (!shieldOn(page)) return false
            val kind = kindOf(r)
            if (kind == Kind.STYLESHEET || kind == Kind.FONT) return false // never: pages must look right
            val e = shields
            val host = hostOf(u)
            val third = siteOf(host) != siteOf(hostOf(page))
            val block = if (e != null) {
                e.blocked(u, page, kind) || (third && BuiltIn.blocked(host) && !e.excepted(u, page, kind))
            } else third && BuiltIn.blocked(host)
            if (block) ui.post { events.onBlocked(t) }
            return block
        }
    }

    inner class Nav(private val t: Tab, private val w: Page) : CefriumNavigationClient {
        override fun onBeforeNavigate(browser: CefriumBrowser, request: CefriumNavigationRequest): Boolean {
            val u = request.url ?: return false
            val s = u.lowercase()
            if (!s.startsWith("http:") && !s.startsWith("https:") && !s.startsWith("about:") && !s.startsWith("data:") && !s.startsWith("blob:")) {
                // another app's link (intent:, tel:, mailto:, market:, whatsapp:):
                // only from a tap, so a page cannot open apps by itself
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
                    ctx.startActivity(i)
                } catch (e: Exception) {
                    // an intent: link with a web fallback opens that instead
                    if (s.startsWith("intent:")) {
                        val fb = Regex("S\\.browser_fallback_url=([^;]+)").find(u)?.groupValues?.get(1)
                        if (fb != null) ui.post { w.loadUrl(Uri.decode(fb)) }
                    }
                }
                return true
            }
            if (!request.isForMainFrame) return false
            // HTTPS-only: try the secure address first
            if (set.httpsOnly && s.startsWith("http://") && hostOf(u) !in insecureOK) {
                upgraded.add(hostOf(u))
                ui.post { w.loadUrl("https://" + u.substring(7)) }
                return true
            }
            if (set.shields && set.cleanLinks) {
                val c = Links.clean(u)
                if (c != u) {
                    ui.post { w.loadUrl(c) }
                    return true
                }
            }
            return false
        }

        override fun onLoadStart(browser: CefriumBrowser, url: String) {
            t.page = url
            t.blocked = 0
            events.onUrl(t, url)
            events.onProgress(t, 5)
        }

        override fun onUrlChanged(browser: CefriumBrowser, url: String) {
            t.page = url
            events.onUrl(t, url)
        }

        override fun onDocumentAvailable(browser: CefriumBrowser) = hide(w, t.page)

        override fun onProgressChanged(browser: CefriumBrowser, percent: Int) = events.onProgress(t, percent)

        override fun onLoadingStateChanged(browser: CefriumBrowser, loading: Boolean, canGoBack: Boolean, canGoForward: Boolean) {
            w.back = canGoBack
            w.forward = canGoForward
            t.canBack = canGoBack
            t.canForward = canGoForward
            if (!loading) {
                hide(w, t.page)
                events.onProgress(t, 100)
                w.onFinished?.invoke(t.page)
            }
        }

        override fun onLoadError(browser: CefriumBrowser, error: CefriumLoadError) {
            // HTTPS-only: a site with no secure version opens over http, once asked
            val u = browser.url ?: return
            if (!u.startsWith("https://")) return
            val h = hostOf(u)
            if (h in upgraded && h !in insecureOK) {
                insecureOK.add(h)
                ui.post { w.loadUrl("http://" + u.substring(8)) }
            }
        }

        override fun onRenderProcessTerminated(browser: CefriumBrowser, status: CefriumRendererTerminationStatus, errorCode: Int) {
            // the page's process ended (out of memory, or crashed): the tab offers a reload
            events.onCrashed(t)
        }
    }

    inner class Chrome(private val t: Tab) : CefriumChromeClient {
        override fun onTitleChanged(browser: CefriumBrowser, title: String?) = events.onTitle(t, title ?: "")

        override fun onFullscreenChanged(browser: CefriumBrowser, fullscreen: Boolean) = events.onFullscreen(t, fullscreen)

        override fun onCreateWindow(browser: CefriumBrowser, popup: CefriumBrowser, url: String?, userGesture: Boolean): Boolean {
            if (!userGesture) return false // no popups the person did not ask for
            events.onNewTab(t, url ?: "", popup)
            return true
        }

        override fun onCloseWindow(browser: CefriumBrowser, popup: CefriumBrowser) = events.onClosePopup(popup)

        override fun onContextMenu(browser: CefriumBrowser, menu: CefriumContextMenu): Boolean {
            val link = menu.linkUrl ?: ""
            val image = menu.sourceUrl ?: ""
            if (link.isEmpty() && image.isEmpty()) return false // text: the engine's own selection menu
            menu.cancel()
            events.onLongPress(t, link, image)
            return true
        }

        // the engine's own file chooser and permission prompts (camera, microphone,
        // location stay off unless the person allows them there)
        override fun onShowFileChooser(browser: CefriumBrowser, params: CefriumFileChooserParams, callback: CefriumFileChooserCallback): Boolean = false
    }

    /** downloads go to the phone's Downloads folder, with a notification */
    inner class Downloads : CefriumBrowser.CefriumDownloadHandler {
        override fun onBeforeDownload(item: CefriumBrowser.DownloadItem, callback: CefriumBrowser.BeforeDownloadCallback) {
            val u = item.url ?: ""
            val name = (item.suggestedName ?: "").ifEmpty { "download" }
            if (!u.startsWith("http")) {
                callback.allow(null) // a file the page made (blob:, data:): saved by the engine
                toast("Downloading $name")
                return
            }
            callback.cancel()
            try {
                val r = DownloadManager.Request(Uri.parse(u))
                item.mimeType?.let { if (it.isNotEmpty()) r.setMimeType(it) }
                r.addRequestHeader("User-Agent", if (set.desktop) desktopAgent() else mobileAgent())
                r.setTitle(name)
                r.setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
                r.setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, name)
                val dm = ctx.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
                // the site's cookies go along, so downloads behind a sign-in work
                CefriumProfile.getDefault().cookieManager.getCookie(u) { c ->
                    ui.post {
                        try {
                            if (!c.isNullOrEmpty()) r.addRequestHeader("Cookie", c)
                            dm.enqueue(r)
                            toast("Downloading $name")
                        } catch (e: Exception) {
                            toast("This download could not start")
                        }
                    }
                }
            } catch (e: Exception) {
                toast("This download could not start")
            }
        }

        override fun onDownloadUpdated(item: CefriumBrowser.DownloadItem) {}
    }

    private fun toast(s: String) = android.widget.Toast.makeText(ctx, s, android.widget.Toast.LENGTH_SHORT).show()

    companion object {
        private val major get() = Cefrium.getChromiumVersion().substringBefore('.')

        /** the phone's own kind of user agent (Chrome on Android) */
        fun mobileAgent() = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/$major.0.0.0 Mobile Safari/537.36"

        /** a computer's user agent, for the desktop version of sites */
        fun desktopAgent() = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/$major.0.0.0 Safari/537.36"
    }
}
