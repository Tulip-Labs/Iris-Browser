package org.tulipanlabs.iris

import android.annotation.SuppressLint
import android.app.Application
import android.graphics.Bitmap
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.os.Message
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
import java.util.UUID

/**
 * One tab: a WebView in its container's profile (cookies, storage and cache
 * of its own), made when the tab first opens something, so a new or
 * restored tab costs nothing until you go to it.
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
    /** an address to open when the tab is next shown */
    var pending: String? = null
    /** the page's history, kept while the tab sleeps */
    var saved: Bundle? = null
    var lastShown = System.currentTimeMillis()
    /** a pop-up whose first address is not checked yet */
    var popupFrom: Tab? = null

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
 * recompositions and the activity's configuration changes.
 */
class BrowserModel(app: Application) : AndroidViewModel(app) {
    val tabs = mutableStateListOf<Tab>()
    var current by mutableStateOf<Tab?>(null)
        private set
    var blocked by mutableStateOf<Blocked?>(null)
    var pressed by mutableStateOf<Pressed?>(null)
    /** a video in full screen (WebView hands Iris its view) */
    var fullscreen by mutableStateOf<View?>(null)
    private var fullscreenDone: WebChromeClient.CustomViewCallback? = null
    /** a page's file field, answered by the activity's picker */
    var fileRequest by mutableStateOf<Pair<ValueCallback<Array<Uri>>, WebChromeClient.FileChooserParams>?>(null)
    /** a page asking for the camera or microphone, answered by the activity */
    var mediaRequest by mutableStateOf<PermissionRequest?>(null)
    private val closed = ArrayDeque<Pair<String, String?>>()

    val containersWork: Boolean = WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)

    init {
        Store.tabs.forEach { s ->
            val c = if (s.container == null || Store.container(s.container) != null) s.container else null
            tabs.add(Tab(c).also { it.pending = s.url; it.title = s.title; it.url = s.url })
        }
        if (tabs.isEmpty()) newTab() else select(tabs[Store.selected.coerceIn(0, tabs.size - 1)])
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
        t.pending?.let { p -> t.pending = null; load(t, p) }
        t.web?.onResume()
        Store.selected = tabs.indexOf(t)
        sleepIdle()
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
        val w = web(t)
        val s = t.saved
        if (s != null && t.pending == null && w.copyBackForwardList().size == 0) {
            t.saved = null
            w.restoreState(s)
            if (w.url != url) w.loadUrl(url)
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
            w.stopLoading()
            w.destroy()
        }
        t.web = null
    }

    /** the private tabs' profile is wiped when the last one closes */
    private fun clearPrivate() {
        if (!containersWork) return
        runCatching {
            val p = ProfileStore.getInstance().getProfile(PRIVATE_PROFILE) ?: return
            p.cookieManager.removeAllCookies(null)
            p.webStorage.deleteAllData()
        }
    }

    fun profileName(t: Tab): String? = when {
        t.container == null -> null
        t.isPrivate -> PRIVATE_PROFILE
        else -> "c-" + t.container
    }

    /** a container's profile and everything its sites kept go */
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
        t.reload()
    }

    /** the tab's WebView, made on first use */
    @SuppressLint("SetJavaScriptEnabled", "RequiresFeature")
    fun web(t: Tab): WebView {
        t.web?.let { return it }
        val w = WebView(getApplication())
        // a container keeps its cookies and site data in a profile of its own
        // (Android System WebView 123 and newer)
        profileName(t)?.let { name ->
            if (containersWork) runCatching {
                ProfileStore.getInstance().getOrCreateProfile(name)
                WebViewCompat.setProfile(w, name)
            }
        }
        w.setBackgroundColor(Color.WHITE)
        val s = w.settings
        s.javaScriptEnabled = true
        s.domStorageEnabled = true
        s.loadWithOverviewMode = true
        s.useWideViewPort = true
        s.setSupportZoom(true)
        s.builtInZoomControls = true
        s.displayZoomControls = false
        s.mediaPlaybackRequiresUserGesture = false
        s.setSupportMultipleWindows(true)
        s.javaScriptCanOpenWindowsAutomatically = false
        s.mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
        s.allowFileAccess = false
        s.allowContentAccess = false
        if (t.isPrivate) s.cacheMode = WebSettings.LOAD_NO_CACHE
        CookieManager.getInstance().setAcceptThirdPartyCookies(w, false)
        w.webViewClient = Client(t)
        w.webChromeClient = Chrome(t)
        w.setDownloadListener { u, agent, disposition, mime, length ->
            val cookies = runCatching { CookieManager.getInstance().getCookie(u) }.getOrNull()
            Downloads.fetch(getApplication(), u, agent, disposition, mime, length, cookies, t.url)
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
        if (t !== current) w.onPause()
        return w
    }

    private inner class Client(val t: Tab) : WebViewClient() {
        override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
            if (request.isForMainFrame) return null
            return Shields.intercept(t.url, request.url.toString())
        }

        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
            val u = request.url
            // a pop-up's first address decides whether it may stay
            t.popupFrom?.let { from ->
                t.popupFrom = null
                if (!popupAllowed(from, u.toString())) {
                    view.post { close(t); blocked = Blocked(u.toString(), from) }
                    return true
                }
            }
            val scheme = u.scheme?.lowercase()
            if (scheme == "http" || scheme == "https" || scheme == "about" || scheme == "data" || scheme == "blob") return false
            // intent:, mailto:, tel: and other apps, only on a tap
            if (request.hasGesture()) runCatching {
                val i = if (scheme == "intent") android.content.Intent.parseUri(u.toString(), android.content.Intent.URI_INTENT_SCHEME)
                else android.content.Intent(android.content.Intent.ACTION_VIEW, u)
                i.addCategory(android.content.Intent.CATEGORY_BROWSABLE)
                i.component = null
                i.selector = null
                i.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
                getApplication<Application>().startActivity(i)
            }
            return true
        }

        override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) {
            t.url = url
            t.loading = true
            t.progress = 5
            t.canBack = view.canGoBack()
            t.canForward = view.canGoForward()
        }

        override fun onPageFinished(view: WebView, url: String) {
            t.loading = false
            t.progress = 100
            t.url = url
            t.canBack = view.canGoBack()
            t.canForward = view.canGoForward()
            if (!t.isPrivate) Store.visit(url, t.title)
            save()
        }

        override fun doUpdateVisitedHistory(view: WebView, url: String, isReload: Boolean) {
            t.url = url
            t.canBack = view.canGoBack()
            t.canForward = view.canGoForward()
        }

        override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
            // the page's process ended (memory or a crash): the tab gets a
            // fresh WebView and opens its page again when shown
            t.web = null
            (view.parent as? ViewGroup)?.removeView(view)
            view.destroy()
            t.pending = t.url.ifEmpty { null }
            if (t === current) t.pending?.let { p -> t.pending = null; load(t, p) }
            return true
        }
    }

    private inner class Chrome(val t: Tab) : WebChromeClient() {
        override fun onProgressChanged(view: WebView, newProgress: Int) {
            t.progress = newProgress
            t.loading = newProgress < 100
        }

        override fun onReceivedTitle(view: WebView, title: String?) { t.title = title ?: "" }

        // pop-ups: only when you tapped; a link opens as a tab, a script's
        // window only to the same site or a sign-in (ads open no tabs)
        override fun onCreateWindow(view: WebView, isDialog: Boolean, isUserGesture: Boolean, resultMsg: Message): Boolean {
            if (!isUserGesture) return false
            val h = view.hitTestResult
            val link = if (h.type == WebView.HitTestResult.SRC_ANCHOR_TYPE || h.type == WebView.HitTestResult.SRC_IMAGE_ANCHOR_TYPE) h.extra else null
            if (link != null && link.startsWith("http")) {
                if (!popupAllowed(t, link) && Search.host(link)?.let(Shields::isBlocked) == true) {
                    blocked = Blocked(link, t); return false
                }
                newTab(link, t.container, after = t)
                return false
            }
            // a script's window: it becomes a tab whose first address is checked
            val nt = Tab(t.container)
            nt.popupFrom = t
            tabs.add(tabs.indexOf(t) + 1, nt)
            val w = web(nt)
            (resultMsg.obj as WebView.WebViewTransport).webView = w
            resultMsg.sendToTarget()
            select(nt)
            return true
        }

        override fun onCloseWindow(window: WebView) {
            tabs.firstOrNull { it.web === window }?.let(::close)
        }

        override fun onShowCustomView(view: View, callback: CustomViewCallback) {
            fullscreen = view
            fullscreenDone = callback
        }

        override fun onHideCustomView() {
            fullscreen = null
            fullscreenDone = null
        }

        override fun onShowFileChooser(webView: WebView, filePathCallback: ValueCallback<Array<Uri>>, fileChooserParams: FileChooserParams): Boolean {
            fileRequest?.first?.onReceiveValue(null)
            fileRequest = filePathCallback to fileChooserParams
            return true
        }

        override fun onPermissionRequest(request: PermissionRequest) {
            // calls (WebRTC): the camera and microphone, which Android lets
            // Iris use once you allow it (the activity asks); protected
            // video (DRM) for streaming sites
            val ok = request.resources.filter {
                it == PermissionRequest.RESOURCE_AUDIO_CAPTURE || it == PermissionRequest.RESOURCE_VIDEO_CAPTURE ||
                    it == PermissionRequest.RESOURCE_PROTECTED_MEDIA_ID
            }
            if (ok.isEmpty()) { request.deny() } else { mediaRequest = request }
        }
    }

    fun popupAllowed(from: Tab, url: String): Boolean {
        val host = Search.host(url) ?: return false
        if (Shields.onFor(from.url) && Shields.isBlocked(host)) return false
        val site = Search.host(from.url)?.let { Search.site(it) }
        return Search.site(host) == site || Search.isSignIn(host)
    }

    fun exitFullscreen() {
        fullscreenDone?.onCustomViewHidden()
        fullscreen = null
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
    }

    companion object {
        const val PRIVATE_PROFILE = "private"
    }
}
