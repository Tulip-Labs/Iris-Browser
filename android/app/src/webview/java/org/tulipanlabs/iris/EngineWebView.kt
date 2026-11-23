package org.tulipanlabs.iris

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.MutableContextWrapper
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
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
import androidx.webkit.ProfileStore
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import java.io.ByteArrayInputStream

/** the engine this flavor carries: Android System WebView */
object EngineFactory {
    fun create(): Engine = WebViewEngine
}

private const val PRIVATE_PROFILE = "private"

/** one page drawn by Android System WebView */
private class WebPage(val web: WebView, private val base: MutableContextWrapper) : PageView {
    override val view: View get() = web
    override fun loadUrl(url: String) = web.loadUrl(url)
    override fun goBack() = web.goBack()
    override fun goForward() = web.goForward()
    override fun reload() = web.reload()
    override fun stopLoading() = web.stopLoading()
    override fun canGoBack(): Boolean = web.canGoBack()
    override fun canGoForward(): Boolean = web.canGoForward()
    override fun onPause() = web.onPause()
    override fun onResume() = web.onResume()
    override fun evaluateJavascript(script: String) {
        runCatching { web.evaluateJavascript(script, null) }
    }

    override fun saveState(): Bundle? {
        val b = Bundle()
        val list = runCatching { web.saveState(b) }.getOrNull()
        return if (list == null || list.size == 0) null else b
    }

    override fun restoreState(state: Bundle): Boolean {
        val list = runCatching { web.restoreState(state) }.getOrNull()
        return (list?.size ?: 0) > 0
    }

    override fun setPreraster(enabled: Boolean) {
        // the shown page is drawn ahead of the scroll, so it moves without gaps
        web.settings.offscreenPreRaster = enabled
    }

    override fun destroy() {
        (web.parent as? ViewGroup)?.removeView(web)
        // the page's context wrapper goes with it
        WebViewEngine.forgetContext(base)
        runCatching { web.destroy() }
    }
}

object WebViewEngine : Engine {
    override val containersSupported: Boolean =
        runCatching { WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE) }.getOrDefault(false)

    override val supportsDocumentStartScript: Boolean =
        runCatching { WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT) }.getOrDefault(false)

    /** the pages' context wrappers: their base is the activity, swapped when it is remade */
    private val contexts = mutableListOf<MutableContextWrapper>()
    private val pages = mutableMapOf<WebView, WebPage>()

    override fun onActivityChanged(activity: Activity?) {
        activity?.let { a -> contexts.forEach { it.baseContext = a } }
    }

    internal fun forgetContext(base: MutableContextWrapper) {
        contexts.remove(base)
    }

    /** the tab's WebView, made on first use (null until the activity is here) */
    @SuppressLint("SetJavaScriptEnabled", "RequiresFeature")
    override fun createPage(tab: Tab, model: BrowserModel): PageView? {
        val act = model.activity ?: return null
        // the activity's context, so pickers and dialogs work, swapped for the
        // new activity if Android remakes it; the look decides the page's
        // prefers-color-scheme
        val base = MutableContextWrapper(act).also { contexts.add(it) }
        val themed = ContextThemeWrapper(base, if (model.dark) R.style.Iris_Dark else R.style.Iris)
        val w = WebView(themed)
        // a container keeps its cookies and site data in a profile of its own
        // (Android System WebView 123 and newer)
        profileName(tab)?.let { name ->
            if (containersSupported) runCatching {
                ProfileStore.getInstance().getOrCreateProfile(name)
                WebViewCompat.setProfile(w, name)
            }
        }
        w.setBackgroundColor(if (model.dark) Color.rgb(18, 16, 28) else Color.WHITE)
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
        if (tab.isPrivate) s.cacheMode = WebSettings.LOAD_NO_CACHE
        CookieManager.getInstance().setAcceptThirdPartyCookies(w, false)
        if (supportsDocumentStartScript) {
            for (script in model.documentScripts) {
                runCatching { WebViewCompat.addDocumentStartJavaScript(w, script.code, script.patterns) }
            }
        }
        w.webViewClient = Client(tab, model)
        w.webChromeClient = Chrome(tab, model)
        w.setDownloadListener { u, agent, disposition, mime, length ->
            val cookies = runCatching { CookieManager.getInstance().getCookie(u) }.getOrNull()
            model.onDownload(tab, u, agent, disposition, mime, length, cookies)
        }
        w.setOnLongClickListener {
            val h = w.hitTestResult
            when (h.type) {
                WebView.HitTestResult.SRC_ANCHOR_TYPE -> { model.onLongPress(tab, h.extra, null); true }
                WebView.HitTestResult.SRC_IMAGE_ANCHOR_TYPE -> {
                    val msg = w.handler.obtainMessage()
                    w.requestFocusNodeHref(msg)
                    model.onLongPress(tab, msg.data.getString("url"), h.extra); true
                }
                WebView.HitTestResult.IMAGE_TYPE -> { model.onLongPress(tab, null, h.extra); true }
                else -> false
            }
        }
        val page = WebPage(w, base)
        pages[w] = page
        return page
    }

    private fun profileName(t: Tab): String? = when {
        t.container == null -> null
        t.isPrivate -> PRIVATE_PROFILE
        else -> "c-" + t.container
    }

    override fun engineName(): String = runCatching {
        val p = WebViewCompat.getCurrentWebViewPackage(IrisApp.instance)
        "Android System WebView ${p?.versionName ?: ""}".trim()
    }.getOrDefault("Android System WebView")

    override fun mobileAgent(): String =
        runCatching { WebSettings.getDefaultUserAgent(IrisApp.instance) }.getOrDefault("")

    /** the private tabs' profile is wiped when the last one closes */
    override fun clearPrivateData() {
        if (!containersSupported) return
        runCatching {
            val p = ProfileStore.getInstance().getProfile(PRIVATE_PROFILE) ?: return
            p.cookieManager.removeAllCookies(null)
            p.webStorage.deleteAllData()
        }
    }

    /** a container's profile and everything its sites kept go */
    override fun deleteProfile(name: String) {
        if (!containersSupported) return
        runCatching { ProfileStore.getInstance().deleteProfile(name) }
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

    // nested, not inner: an object has no outer instance for inner to hold,
    // so the outer members below are reached through WebViewEngine itself
    private class Client(val t: Tab, val model: BrowserModel) : WebViewClient() {
        override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
            if (!model.shouldBlockRequest(t, request.url.toString(), WebViewEngine.kindOf(request), request.isForMainFrame)) return null
            return WebViewEngine.empty()
        }

        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean =
            model.shouldOverrideNavigation(t, request.url.toString(), request.isForMainFrame, request.hasGesture(), request.isRedirect, WebViewEngine.tappedLinkHost(view))

        override fun onPageStarted(view: WebView, url: String, favicon: android.graphics.Bitmap?) {
            model.onPageStarted(t, url)
        }

        override fun onPageCommitVisible(view: WebView, url: String) {
            model.onPageCommitVisible(t, url)
        }

        // a certificate that fails: that site opens in the sandbox, without asking
        @SuppressLint("WebViewClientOnReceivedSslError")
        override fun onReceivedSslError(view: WebView, handler: android.webkit.SslErrorHandler, error: android.net.http.SslError) {
            handler.cancel()
            val u = error.url ?: return
            model.onSslError(t, u)
        }

        override fun onPageFinished(view: WebView, url: String) {
            model.onPageFinished(t, url)
        }

        override fun doUpdateVisitedHistory(view: WebView, url: String, isReload: Boolean) {
            model.onUrlChanged(t, url)
        }

        override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
            model.onRendererGone(t)
            return true
        }
    }

    private class Chrome(val t: Tab, val model: BrowserModel) : WebChromeClient() {
        override fun onProgressChanged(view: WebView, newProgress: Int) {
            model.onProgress(t, newProgress)
        }

        override fun onReceivedTitle(view: WebView, title: String?) {
            model.onTitle(t, title ?: "")
        }

        // New tabs and pop-ups. Only from a tap: a page cannot open one by
        // itself. A tapped link to an ad opens nothing; another link opens as
        // a tab. A script's window is made hidden and shown only once its
        // first address is known to be the same site or a sign-in, so ads
        // that open in a new tab never appear.
        override fun onCreateWindow(view: WebView, isDialog: Boolean, isUserGesture: Boolean, resultMsg: Message): Boolean {
            if (!isUserGesture) { model.onBlocked(t); return false }
            val h = view.hitTestResult
            val link = if (h.type == WebView.HitTestResult.SRC_ANCHOR_TYPE) h.extra else if (h.type == WebView.HitTestResult.SRC_IMAGE_ANCHOR_TYPE) {
                val msg = view.handler.obtainMessage()
                view.requestFocusNodeHref(msg)
                msg.data.getString("url")
            } else null
            if (link != null && link.startsWith("http")) {
                if (model.isAd(t, link)) { model.onBlocked(t); return false }
                model.newTab(link, t.container, after = t)
                return false
            }
            val nt = model.newHeldTab(t) ?: return false
            val page = model.web(nt) as? WebPage ?: run { model.dropHeldTab(nt); return false }
            (resultMsg.obj as WebView.WebViewTransport).webView = page.web
            resultMsg.sendToTarget()
            model.schedulePopupTimeout(nt, t)
            return true
        }

        override fun onCloseWindow(window: WebView) {
            WebViewEngine.pages[window]?.let { model.closeWindow(it) }
        }

        override fun onShowCustomView(view: View, callback: CustomViewCallback) {
            if (t !== model.current) { callback.onCustomViewHidden(); return }
            model.onFullscreen(t, view) { callback.onCustomViewHidden() }
        }

        override fun onHideCustomView() {
            model.onFullscreen(t, null) {}
        }

        override fun onShowFileChooser(webView: WebView, filePathCallback: ValueCallback<Array<Uri>>, fileChooserParams: FileChooserParams): Boolean {
            model.onFileChooser(t, FileRequest(
                createIntent = { runCatching { fileChooserParams.createIntent() }.getOrNull() },
                parseResult = { code, data -> FileChooserParams.parseResult(code, data) },
                answer = { filePathCallback.onReceiveValue(it) },
            ))
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
            if (ok.isEmpty()) {
                request.deny()
                return
            }
            model.onMediaRequest(t, MediaRequest(
                resources = ok.map {
                    when (it) {
                        PermissionRequest.RESOURCE_VIDEO_CAPTURE -> PagePermission.CAMERA
                        PermissionRequest.RESOURCE_AUDIO_CAPTURE -> PagePermission.MICROPHONE
                        else -> PagePermission.PROTECTED_MEDIA
                    }
                },
                grant = { granted ->
                    request.grant(granted.map {
                        when (it) {
                            PagePermission.CAMERA -> PermissionRequest.RESOURCE_VIDEO_CAPTURE
                            PagePermission.MICROPHONE -> PermissionRequest.RESOURCE_AUDIO_CAPTURE
                            PagePermission.PROTECTED_MEDIA -> PermissionRequest.RESOURCE_PROTECTED_MEDIA_ID
                        }
                    }.toTypedArray())
                },
                deny = { request.deny() },
            ))
        }
    }
}
