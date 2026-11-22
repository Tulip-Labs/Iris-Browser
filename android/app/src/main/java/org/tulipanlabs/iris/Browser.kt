package org.tulipanlabs.iris

import android.annotation.SuppressLint
import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.Intent
import android.content.MutableContextWrapper
import android.graphics.Bitmap
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Message
import android.view.ContextThemeWrapper
import android.view.View
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.PermissionRequest
import android.webkit.RenderProcessGoneDetail
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.webkit.ProfileStore
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import java.io.ByteArrayInputStream
import java.util.UUID

/**
 * One tab: a WebView (Android System WebView, Chromium kept up to date by
 * the phone) in its container's profile, made when the tab first opens
 * something, so a new or restored tab costs nothing until you go to it.
 */
class Tab(val container: String?, url: String = "") {
    val id: String = UUID.randomUUID().toString()
    var url by mutableStateOf(url)
    var title by mutableStateOf("")
    var progress by mutableIntStateOf(0)
    var loading by mutableStateOf(false)
    var canBack by mutableStateOf(false)
    var canForward by mutableStateOf(false)
    var web by mutableStateOf<WebView?>(null)
    /** ads, trackers and pop-ups stopped on this page */
    var blocked by mutableIntStateOf(0)
    /** an address to open when the tab is next shown */
    var pending: String? = null
    /** the page's history, kept while the tab sleeps */
    var saved: Bundle? = null
    var lastShown = System.currentTimeMillis()
    var crashed by mutableStateOf(false)
    /** a pop-up whose first address is not checked yet: it stays hidden until then */
    var popupFrom: Tab? = null
    /** the page's address for the network thread (Compose state is read on the main thread) */
    @Volatile var top: String = url

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
 * The tabs and their WebViews, kept here so they outlive Compose's
 * recompositions and the activity.
 */
class BrowserModel(app: Application) : AndroidViewModel(app) {
    val tabs = mutableStateListOf<Tab>()
    var current by mutableStateOf<Tab?>(null)
        private set
    var blocked by mutableStateOf<Blocked?>(null)
    var pressed by mutableStateOf<Pressed?>(null)
    /** a video in full screen: WebView hands Iris its view, and the bars step aside */
    var fullscreenView by mutableStateOf<View?>(null)
        private set
    val fullscreen get() = fullscreenView != null
    private var fullscreenDone: WebChromeClient.CustomViewCallback? = null
    /** a page's file field, answered by the activity's picker */
    var fileRequest by mutableStateOf<Pair<ValueCallback<Array<Uri>>, WebChromeClient.FileChooserParams>?>(null)
    /** a page asking for the camera or microphone, answered by the activity */
    var mediaRequest by mutableStateOf<PermissionRequest?>(null)
    /** the activity: pages are made in its context (dialogs, pickers), swapped when it is remade */
    var activity: Activity? = null
        set(v) { field = v; v?.let { a -> contexts.forEach { it.setBaseContext(a) } } }
    private val contexts = mutableListOf<MutableContextWrapper>()
    private val closed = ArrayDeque<Pair<String, String?>>()
    /** pop-ups made but not shown: each waits for its first address */
    private val held = mutableListOf<Tab>()
    /** a tab already open on Google AI Mode, waiting for the next new tab */
    private var spare: Tab? = null
    private val ui = Handler(Looper.getMainLooper())
    private val ctx: Context get() = getApplication()
    /** Iris is light: pages see prefers-color-scheme: light */
    var dark = false

    val containersWork: Boolean = runCatching { WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE) }.getOrDefault(false)

    init {
        Store.tabs.forEach { s ->
            val c = if (s.container == null || Store.container(s.container) != null) s.container else null
            tabs.add(Tab(c).also { it.pending = s.url; it.title = s.title; it.url = s.url })
        }
        if (tabs.isEmpty()) newTab() else select(tabs[Store.selected.coerceIn(0, tabs.size - 1)])
        Shields.changed = { synchronized(css) { css.clear() } }
    }

    fun newTab(url: String? = null, container: String? = null, after: Tab? = null, select: Boolean = true): Tab {
        // a plain new tab is Google AI Mode: the spare one, already loaded, when there is one
        val plain = url.isNullOrEmpty()
        val sp = spare?.takeIf { plain && container == null && it.web != null }
        val t = sp ?: Tab(container)
        if (sp != null) spare = null
        val i = after?.let { tabs.indexOf(it) } ?: -1
        if (i >= 0) tabs.add(i + 1, t) else tabs.add(t)
        val u = if (plain) Search.HOME else url!!
        if (sp == null) {
            t.url = u
            if (select) load(t, u) else t.pending = u
        }
        if (select || current == null) select(t)
        save()
        prepareSpare()
        return t
    }

    /** the next new tab, loaded in the background a moment after this one */
    private fun prepareSpare() {
        if (spare != null) return
        ui.postDelayed({
            if (spare != null || activity == null) return@postDelayed
            val s = Tab(null, Search.HOME)
            val w = web(s) ?: return@postDelayed
            spare = s
            w.loadUrl(Search.HOME)
        }, 1500)
    }

    fun select(t: Tab) {
        current?.let { it.lastShown = System.currentTimeMillis(); it.web?.onPause(); it.web?.settings?.offscreenPreRaster = false }
        current = t
        t.lastShown = System.currentTimeMillis()
        t.pending?.let { p -> if (activity != null) { t.pending = null; load(t, p) } }
        // a tab with nothing in it opens Google AI Mode
        if (t.web == null && t.pending == null && activity != null) load(t, t.url.ifEmpty { Search.HOME })
        t.web?.onResume()
        // the shown page is drawn ahead of the scroll, so it moves without gaps
        t.web?.settings?.offscreenPreRaster = true
        Store.selected = tabs.indexOf(t)
    }

    /** the activity is here: the shown tab opens what it was waiting for */
    fun attached(a: Activity) {
        activity = a
        current?.let { t ->
            t.pending?.let { p -> t.pending = null; load(t, p) }
            if (t.web == null) load(t, t.url.ifEmpty { Search.HOME })
        }
        prepareSpare()
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
        // a site Iris does not trust opens in the sandbox, and the tab stays as it was
        if (Search.untrusted(url)) {
            activity?.let { SandboxActivity.open(it, url) } ?: SandboxActivity.open(ctx, url)
            if (t.web == null && t.url == url) { t.url = Search.HOME; load(t, Search.HOME) }
            return
        }
        t.url = url
        t.top = url
        t.crashed = false
        val w = web(t) ?: run { t.pending = url; return }
        val s = t.saved
        if (s != null) {
            t.saved = null
            val list = runCatching { w.restoreState(s) }.getOrNull()
            if (list == null || list.size == 0) w.loadUrl(url)
        } else {
            w.loadUrl(url)
        }
        save()
    }

    /** home: Google AI Mode, in this tab */
    fun home(t: Tab) = load(t, Search.HOME)

    private fun destroy(t: Tab) {
        t.web?.let { w ->
            (w.parent as? ViewGroup)?.removeView(w)
            runCatching { w.stopLoading() }
            ((w.context as? ContextThemeWrapper)?.baseContext as? MutableContextWrapper)?.let { c -> contexts.remove(c) }
            runCatching { w.destroy() }
        }
        t.web = null
    }

    // ---- profiles: containers and private tabs ----

    /** the private tabs' profile is wiped when the last one closes */
    private fun clearPrivate() {
        if (!containersWork) return
        runCatching {
            val p = ProfileStore.getInstance().getProfile(PRIVATE_PROFILE) ?: return
            p.cookieManager.removeAllCookies(null)
            p.webStorage.deleteAllData()
        }
    }

    private fun profileName(t: Tab): String? = when {
        t.container == null -> null
        t.isPrivate -> PRIVATE_PROFILE
        else -> "c-" + t.container
    }

    /** a container's tabs close, and its profile and everything its sites kept go */
    fun removeContainer(id: String) {
        tabs.filter { it.container == id }.forEach(::close)
        if (containersWork) runCatching { ProfileStore.getInstance().deleteProfile("c-$id") }
    }

    fun shieldsFor(url: String) = Shields.onFor(url)

    fun toggleSiteShields(t: Tab) {
        val h = Search.host(t.url) ?: return
        val site = Search.site(h)
        val off = Store.shieldsOff.toMutableSet()
        if (!off.add(site)) off.remove(site)
        Store.shieldsOff = off
        synchronized(css) { css.clear() }
        t.reload()
    }

    fun shieldsChanged() {
        synchronized(css) { css.clear() }
        current?.reload()
    }

    // ---- the engine ----

    private val youtube by lazy { runCatching { ctx.assets.open("js/youtube.js").bufferedReader().use { it.readText() } }.getOrDefault("") }
    private val aiGlass by lazy { runCatching { ctx.assets.open("js/aimode.js").bufferedReader().use { it.readText() } }.getOrDefault("") }

    /** the tab's WebView, made on first use (null until the activity is here) */
    @SuppressLint("SetJavaScriptEnabled", "RequiresFeature")
    fun web(t: Tab): WebView? {
        t.web?.let { return it }
        val act = activity ?: return null
        // the activity's context, so pickers and dialogs work, swapped for the
        // new activity if Android remakes it; the look decides the page's
        // prefers-color-scheme
        val base = MutableContextWrapper(act).also { contexts.add(it) }
        val themed = ContextThemeWrapper(base, if (dark) R.style.Iris_Dark else R.style.Iris)
        val w = WebView(themed)
        // a container keeps its cookies and site data in a profile of its own
        // (Android System WebView 123 and newer)
        profileName(t)?.let { name ->
            if (containersWork) runCatching {
                ProfileStore.getInstance().getOrCreateProfile(name)
                WebViewCompat.setProfile(w, name)
            }
        }
        w.setBackgroundColor(if (dark) Color.rgb(18, 16, 28) else Color.WHITE)
        val s = w.settings
        s.javaScriptEnabled = true
        s.domStorageEnabled = true
        s.loadWithOverviewMode = true
        s.useWideViewPort = true
        s.setSupportZoom(true)
        s.builtInZoomControls = true
        s.displayZoomControls = false
        s.mediaPlaybackRequiresUserGesture = false
        // windows only through onCreateWindow, where Iris checks them; a
        // script cannot open one by itself
        s.setSupportMultipleWindows(true)
        s.javaScriptCanOpenWindowsAutomatically = false
        s.mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
        s.allowFileAccess = false
        s.allowContentAccess = false
        if (t.isPrivate) s.cacheMode = WebSettings.LOAD_NO_CACHE
        CookieManager.getInstance().setAcceptThirdPartyCookies(w, false)
        if (WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
            if (youtube.isNotBlank()) runCatching { WebViewCompat.addDocumentStartJavaScript(w, youtube, setOf("https://*.youtube.com", "https://youtube.com")) }
            // Iris's glass on Google AI Mode, the home of every tab
            if (aiGlass.isNotBlank()) runCatching { WebViewCompat.addDocumentStartJavaScript(w, aiGlass, setOf("https://www.google.com", "https://google.com")) }
        }
        w.webViewClient = Client(t)
        w.webChromeClient = Chrome(t)
        w.setDownloadListener { u, agent, disposition, mime, length ->
            val cookies = runCatching { CookieManager.getInstance().getCookie(u) }.getOrNull()
            Downloads.fetch(ctx, u, agent, disposition, mime, length, cookies, t.url)
        }
        w.setOnLongClickListener {
            val h = w.hitTestResult
            when (h.type) {
                WebView.HitTestResult.SRC_ANCHOR_TYPE -> { pressed = Pressed(t, h.extra, null); true }
                WebView.HitTestResult.SRC_IMAGE_ANCHOR_TYPE -> {
                    val msg = w.handler.obtainMessage()
                    w.requestFocusNodeHref(msg)
                    pressed = Pressed(t, msg.data.getString("url"), h.extra); true
                }
                WebView.HitTestResult.IMAGE_TYPE -> { pressed = Pressed(t, null, h.extra); true }
                else -> false
            }
        }
        t.web = w
        if (t !== current && t.popupFrom == null) w.onPause()
        return w
    }

    /** a held pop-up went somewhere allowed: it becomes a tab beside its page */
    private fun approve(p: Tab, from: Tab) {
        if (!held.remove(p)) return
        val i = tabs.indexOf(from)
        if (i >= 0) tabs.add(i + 1, p) else tabs.add(p)
        select(p)
        save()
    }

    /** a held pop-up went to an ad, or elsewhere: it goes, never shown */
    private fun deny(p: Tab, from: Tab, url: String?) {
        if (!held.remove(p)) return
        destroy(p)
        from.blocked++
        // not an ad, just another site: the notice offers to open it
        if (url != null && url.startsWith("http") && !isAd(from, url)) blocked = Blocked(url, from)
    }

    /** what a request is, for the filter lists: the Accept header and the address say */
    private fun kindOf(r: WebResourceRequest): Int {
        val accept = (r.requestHeaders["Accept"] ?: r.requestHeaders["accept"] ?: "").lowercase()
        val p = (r.url.path ?: "").lowercase()
        return when {
            accept.startsWith("text/css") || p.endsWith(".css") -> Kind.STYLESHEET
            p.endsWith(".woff") || p.endsWith(".woff2") || p.endsWith(".ttf") || p.endsWith(".otf") -> Kind.FONT
            accept.startsWith("image/") || listOf(".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".avif", ".ico").any { p.endsWith(it) } -> Kind.IMAGE
            accept.startsWith("text/html") -> Kind.SUBDOCUMENT
            p.endsWith(".js") || p.endsWith(".mjs") -> Kind.SCRIPT
            listOf(".mp4", ".webm", ".m3u8", ".mp3", ".m4s").any { p.endsWith(it) } -> Kind.MEDIA
            accept.contains("json") || r.requestHeaders.keys.any { it.equals("X-Requested-With", true) } -> Kind.XHR
            else -> Kind.OTHER
        }
    }

    /** an answer with nothing in it: what a stopped request gets */
    private fun empty() = WebResourceResponse("text/plain", "utf-8", 204, "No Content", mapOf("Access-Control-Allow-Origin" to "*"), ByteArrayInputStream(ByteArray(0)))

    /** the style sheet hiding what ads leave on each site, kept for a few sites */
    private val css = object : LinkedHashMap<String, String>(32, 0.75f, true) {
        override fun removeEldestEntry(e: MutableMap.MutableEntry<String, String>?) = size > 24
    }

    private fun hide(w: WebView, page: String) {
        if (!page.startsWith("http")) return
        val host = hostOf(page)
        val sheet = synchronized(css) { css[host] ?: Shields.core.hidingCSS(page).also { css[host] = it } }
        if (sheet.isEmpty()) return
        val js = "(() => { const add = () => { let s = document.getElementById('iris-shields'); if (!s) { s = document.createElement('style'); " +
            "s.id = 'iris-shields'; (document.head || document.documentElement).appendChild(s); } if (!s.textContent) s.textContent = " +
            org.json.JSONObject.quote(sheet) + "; }; if (document.documentElement) add(); else document.addEventListener('DOMContentLoaded', add); })();"
        runCatching { w.evaluateJavascript(js, null) }
    }

    /** whether going to `url` in the page `from` is an ad or tracker (the domain list, then the lists' rules) */
    private fun isAd(from: Tab, url: String): Boolean {
        if (!url.startsWith("http") || !Shields.onFor(from.top)) return false
        val host = Search.host(url) ?: return false
        if (ShieldCore.never(host)) return false
        if (Shields.isBlocked(host)) return true
        return Shields.core.blocks(url, from.top.ifEmpty { url }, Kind.SUBDOCUMENT, false)
    }

    private inner class Client(val t: Tab) : WebViewClient() {
        // Iris Shields: WebView asks before every request, on its network
        // thread; what is stopped never leaves the phone
        override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
            if (request.isForMainFrame) return null
            val u = request.url.toString()
            val page = t.top
            if (!Shields.core.blocks(u, page, kindOf(request), false)) return null
            ui.post { t.blocked++ }
            return empty()
        }

        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
            val u = request.url
            val us = u.toString()
            // a pop-up's first address decides whether it may stay, before it is shown
            t.popupFrom?.let { from ->
                // sign-in windows often open empty first, then get their address
                if (!request.isForMainFrame || us == "about:blank") return false
                t.popupFrom = null
                if (!popupAllowed(from, us)) {
                    ui.post { deny(t, from, us) }
                    return true
                }
                ui.post { approve(t, from) }
            }
            val scheme = u.scheme?.lowercase()
            if (request.isForMainFrame) {
                // a Google result: straight to it, without Google's redirect
                Search.unwrapRedirect(us)?.let { target -> ui.post { view.loadUrl(target) }; return true }
                // a site Iris does not trust: the sandbox, without asking
                if ((scheme == "http" || scheme == "https") && Search.untrusted(us)) {
                    activity?.let { SandboxActivity.open(it, us) }
                    return true
                }
            }
            if (scheme == "http" || scheme == "https") {
                // ads that take the page itself away: a redirect, or a script
                // sending the tab to an ad without a tap on a link to it
                if (request.isForMainFrame && t.url.isNotEmpty() && isAd(t, us)) {
                    val tapped = request.hasGesture() && tappedLinkHost(view) == u.host?.lowercase()
                    if (!tapped || request.isRedirect) {
                        ui.post { t.blocked++ }
                        return true
                    }
                }
                return false
            }
            if (scheme == "about" || scheme == "data" || scheme == "blob") return false
            // intent:, mailto:, tel: and other apps, only on a tap, so a page
            // cannot open apps by itself
            if (!request.hasGesture()) return true
            try {
                val i = if (scheme == "intent") Intent.parseUri(us, Intent.URI_INTENT_SCHEME) else Intent(Intent.ACTION_VIEW, u)
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
                if (scheme == "intent") {
                    Regex("S\\.browser_fallback_url=([^;]+)").find(us)?.groupValues?.get(1)?.let { fb ->
                        val f = Uri.decode(fb)
                        if (f.startsWith("http")) ui.post { view.loadUrl(f) }
                    }
                }
            }
            return true
        }

        override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) {
            // a pop-up that went straight to its address (no override asked):
            // checked here instead
            t.popupFrom?.let { from ->
                if (url == "about:blank" || url.isEmpty()) return
                t.popupFrom = null
                if (!popupAllowed(from, url)) {
                    view.stopLoading()
                    ui.post { deny(t, from, url) }
                    return
                }
                ui.post { approve(t, from) }
            }
            t.url = url
            t.top = url
            t.blocked = 0
            t.loading = true
            t.progress = 5
            t.canBack = view.canGoBack()
            t.canForward = view.canGoForward()
        }

        override fun onPageCommitVisible(view: WebView, url: String) {
            hide(view, url)
            // where WebView cannot add the glass before the page, it comes now
            if (Search.isAIMode(url) && !WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT) && aiGlass.isNotBlank()) {
                runCatching { view.evaluateJavascript(aiGlass, null) }
            }
        }

        // a certificate that fails: that site opens in the sandbox, without asking
        @SuppressLint("WebViewClientOnReceivedSslError")
        override fun onReceivedSslError(view: WebView, handler: android.webkit.SslErrorHandler, error: android.net.http.SslError) {
            handler.cancel()
            val u = error.url ?: return
            if (u == t.top || Search.host(u) == Search.host(t.top)) {
                activity?.let { SandboxActivity.open(it, u, cert = true) }
                ui.post { if (t.web?.canGoBack() == true) t.web?.goBack() else load(t, Search.HOME) }
            }
        }

        override fun onPageFinished(view: WebView, url: String) {
            t.loading = false
            t.progress = 100
            t.url = url
            t.top = url
            t.canBack = view.canGoBack()
            t.canForward = view.canGoForward()
            hide(view, url)
            if (!t.isPrivate && url.startsWith("http")) Store.visit(url, t.title)
            save()
        }

        override fun doUpdateVisitedHistory(view: WebView, url: String, isReload: Boolean) {
            t.url = url
            t.top = url
            t.canBack = view.canGoBack()
            t.canForward = view.canGoForward()
        }

        override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
            // the page's process ended (memory or a crash): the tab gets a
            // fresh WebView and opens its page again when shown
            destroy(t)
            t.pending = t.url.ifEmpty { null }
            t.crashed = true
            if (t === current) t.pending?.let { p -> t.pending = null; load(t, p) }
            return true
        }
    }

    /** the host of the link under the last tap, if it was a link */
    private fun tappedLinkHost(w: WebView): String? {
        val h = w.hitTestResult
        val link = when (h.type) {
            WebView.HitTestResult.SRC_ANCHOR_TYPE -> h.extra
            WebView.HitTestResult.SRC_IMAGE_ANCHOR_TYPE -> {
                val msg = w.handler.obtainMessage()
                w.requestFocusNodeHref(msg)
                msg.data.getString("url")
            }
            else -> null
        }
        return link?.let { Search.host(it) }
    }

    private inner class Chrome(val t: Tab) : WebChromeClient() {
        override fun onProgressChanged(view: WebView, newProgress: Int) {
            t.progress = newProgress
            t.loading = newProgress < 100
        }

        override fun onReceivedTitle(view: WebView, title: String?) { t.title = title ?: "" }

        // New tabs and pop-ups. Only from a tap: a page cannot open one by
        // itself. A tapped link to an ad opens nothing; another link opens as
        // a tab. A script's window is made hidden and shown only once its
        // first address is known to be the same site or a sign-in, so ads
        // that open in a new tab never appear.
        override fun onCreateWindow(view: WebView, isDialog: Boolean, isUserGesture: Boolean, resultMsg: Message): Boolean {
            if (!isUserGesture) { t.blocked++; return false }
            val h = view.hitTestResult
            val link = if (h.type == WebView.HitTestResult.SRC_ANCHOR_TYPE) h.extra else if (h.type == WebView.HitTestResult.SRC_IMAGE_ANCHOR_TYPE) {
                val msg = view.handler.obtainMessage()
                view.requestFocusNodeHref(msg)
                msg.data.getString("url")
            } else null
            if (link != null && link.startsWith("http")) {
                if (isAd(t, link)) { t.blocked++; return false }
                newTab(link, t.container, after = t)
                return false
            }
            val nt = Tab(t.container)
            nt.popupFrom = t
            held.add(nt)
            val w = web(nt) ?: run { held.remove(nt); return false }
            (resultMsg.obj as WebView.WebViewTransport).webView = w
            resultMsg.sendToTarget()
            // it went nowhere: the pop-up goes
            ui.postDelayed({ if (nt.popupFrom != null) { nt.popupFrom = null; deny(nt, t, null) } }, 8000)
            return true
        }

        override fun onCloseWindow(window: WebView) {
            held.firstOrNull { it.web === window }?.let { p -> held.remove(p); destroy(p); return }
            tabs.firstOrNull { it.web === window }?.let(::close)
        }

        override fun onShowCustomView(view: View, callback: CustomViewCallback) {
            if (t !== current) { callback.onCustomViewHidden(); return }
            fullscreenView = view
            fullscreenDone = callback
        }

        override fun onHideCustomView() {
            fullscreenView = null
            fullscreenDone = null
        }

        override fun onShowFileChooser(webView: WebView, filePathCallback: ValueCallback<Array<Uri>>, fileChooserParams: FileChooserParams): Boolean {
            fileRequest?.first?.onReceiveValue(null)
            fileRequest = filePathCallback to fileChooserParams
            return true
        }

        override fun onPermissionRequest(request: PermissionRequest) {
            // calls (WebRTC): the camera and microphone, which Android lets
            // Iris use once you allow it (the activity asks); protected video
            // (DRM) for streaming sites
            val ok = request.resources.filter {
                it == PermissionRequest.RESOURCE_AUDIO_CAPTURE || it == PermissionRequest.RESOURCE_VIDEO_CAPTURE ||
                    it == PermissionRequest.RESOURCE_PROTECTED_MEDIA_ID
            }
            if (ok.isEmpty()) request.deny() else mediaRequest = request
        }
    }

    /** a pop-up may open as a tab: the same site, or a sign-in, and never an ad */
    fun popupAllowed(from: Tab, url: String): Boolean {
        val host = Search.host(url) ?: return false
        if (isAd(from, url)) return false
        val site = Search.host(from.url)?.let { Search.site(it) }
        return Search.site(host) == site || Search.isSignIn(host)
    }

    fun exitFullscreen() {
        fullscreenDone?.onCustomViewHidden()
        fullscreenView = null
        fullscreenDone = null
    }

    fun save() {
        Store.tabs = tabs.filter { !it.isPrivate && (it.pending ?: it.url).isNotEmpty() }
            .map { SavedTab(it.pending ?: it.url, it.title, it.container) }
        current?.let { Store.selected = tabs.indexOf(it) }
    }

    override fun onCleared() {
        save()
        tabs.forEach(::destroy)
        held.forEach(::destroy)
        spare?.let(::destroy)
    }

    companion object {
        const val PRIVATE_PROFILE = "private"
    }
}

/** the engine's names, for the about line and downloads */
object Pages {
    fun engine(): String = runCatching {
        val p = WebViewCompat.getCurrentWebViewPackage(IrisApp.instance)
        "Android System WebView ${p?.versionName ?: ""}".trim()
    }.getOrDefault("Android System WebView")

    fun mobileAgent(): String = runCatching { WebSettings.getDefaultUserAgent(IrisApp.instance) }.getOrDefault("")
}
