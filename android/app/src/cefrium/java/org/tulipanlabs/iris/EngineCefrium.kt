package org.tulipanlabs.iris

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.Toast
import com.cefrium.Cefrium
import com.cefrium.CefriumBrowser
import com.cefrium.CefriumChromeClient
import com.cefrium.CefriumContextMenu
import com.cefrium.CefriumFileChooserCallback
import com.cefrium.CefriumFileChooserParams
import com.cefrium.CefriumLoadError
import com.cefrium.CefriumNavigationClient
import com.cefrium.CefriumNavigationRequest
import com.cefrium.CefriumPermission
import com.cefrium.CefriumPermissionRequest
import com.cefrium.CefriumProfile
import com.cefrium.CefriumRendererTerminationStatus
import com.cefrium.CefriumResourceInterceptor

/**
 * The engine this flavor carries: its own Chromium (CEF, through Cefrium
 * 0.21.0, Chromium 156), the same engine on every phone. Adapted from the
 * 1.0.24 Cefrium line to the 2.2 model (tabs, Shields, Store, the sandbox).
 *
 * Cefrium's renderer processes run IrisApp.onCreate too; the maintainer's
 * fix (an early return in those processes) is in IrisApp, and the next
 * Cefrium release keeps the Application out of its processes by itself.
 * This engine only runs in the main process.
 */

/** the engine this flavor carries: Cefrium, its own Chromium */
object EngineFactory {
    fun create(): Engine = CefriumEngine
}

/** one page: one Chromium browser drawn into a view */
private class CefriumPage(ctx: Context, val b: CefriumBrowser) : FrameLayout(ctx), PageView {
    override val view: android.view.View get() = this

    init {
        addView(b.surfaceContainer, LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
    }

    override fun loadUrl(url: String) = b.loadUrl(url)
    override fun goBack() = b.goBack()
    override fun goForward() = b.goForward()
    override fun reload() = b.reload()
    override fun stopLoading() = b.stopLoading()
    override fun canGoBack(): Boolean = b.canGoBack()
    override fun canGoForward(): Boolean = b.canGoForward()
    override fun onPause() = b.onPause()
    override fun onResume() = b.onResume()

    override fun evaluateJavascript(script: String) {
        runCatching { b.evaluateJavaScript(script) }
    }

    /** the back and forward history, kept while the page sleeps */
    override fun saveState(): Bundle? {
        val out = Bundle()
        runCatching { b.serializeNavigationState()?.let { out.putByteArray("nav", it) } }
        out.putString("url", b.url ?: "")
        return if (out.getByteArray("nav") == null) null else out
    }

    /** puts saved history back; false when there was none to put back */
    override fun restoreState(state: Bundle): Boolean {
        val nav = state.getByteArray("nav") ?: return false
        return runCatching { b.restoreNavigationState(nav); true }.getOrDefault(false)
    }

    /** Chromium draws ahead of the scroll itself; there is no setting for it */
    override fun setPreraster(enabled: Boolean) {}

    override fun destroy() {
        (parent as? ViewGroup)?.removeView(this)
        runCatching { b.close() }
    }
}

object CefriumEngine : Engine {
    // profiles are a Cefrium feature: containers always work here
    override val containersSupported: Boolean = true
    // scripts run before a page's own, natively
    override val supportsDocumentStartScript: Boolean = true

    private val ui = Handler(Looper.getMainLooper())
    private val pages = mutableMapOf<CefriumBrowser, CefriumPage>()

    /** every container keeps its own sign-ins: the engine has profiles */
    private fun profileOf(t: Tab): CefriumProfile = when {
        t.isPrivate -> CefriumProfile.incognito()
        t.container != null -> CefriumProfile.get("c-" + t.container.lowercase().map { if (it.isLetterOrDigit()) it else '_' }.joinToString("").take(60))
        else -> CefriumProfile.getDefault()
    }

    /** the tab's page, made on first use (null until the activity is here) */
    override fun createPage(tab: Tab, model: BrowserModel): PageView? {
        val act = model.activity ?: return null
        val b = CefriumBrowser.createWithSurface(act, profileOf(tab))
        return wrap(tab, model, b)
    }

    /** a page around a browser: a fresh one, or a window a page opened */
    private fun wrap(tab: Tab, model: BrowserModel, b: CefriumBrowser): CefriumPage {
        val w = CefriumPage(model.activity ?: IrisApp.instance, b)
        b.setPinchToZoomEnabled(true)
        b.setPullToRefreshEnabled(false)
        for (script in model.documentScripts) {
            runCatching { b.addDocumentStartJavaScript(script.code, script.patterns) }
        }
        b.setResourceInterceptor(Shield(tab, model))
        b.setNavigationClient(Nav(tab, model))
        b.setChromeClient(Chrome(tab, model, w))
        b.setDownloadHandler(Downloads(tab, model))
        pages[b] = w
        return w
    }

    override fun engineName(): String =
        "Cefrium ${Cefrium.getVersion()} (Chromium ${Cefrium.getChromiumVersion()})"

    /** the phone's own kind of user agent (Chrome on Android) */
    override fun mobileAgent(): String {
        val major = Cefrium.getChromiumVersion().substringBefore('.')
        return "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/$major.0.0.0 Mobile Safari/537.36"
    }

    /** the private tabs' profile is wiped when the last one closes */
    override fun clearPrivateData() {
        runCatching {
            val p = CefriumProfile.incognito()
            p.cookieManager.removeAllCookies {}
            p.cookieManager.flush {}
            p.listSiteData { sites -> sites.forEach { p.clearSiteData(it.site) {} } }
        }
    }

    /** a container's profile and everything its sites kept go */
    override fun deleteProfile(name: String) {
        runCatching { CefriumProfile.delete(name) }
    }

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

    /** Iris Shields: the engine asks before every request, on its network
     *  thread; what is stopped never leaves the phone */
    // nested, not inner: an object has no outer instance for inner to hold,
    // so the outer members below are reached through CefriumEngine itself
    private class Shield(private val t: Tab, private val model: BrowserModel) : CefriumResourceInterceptor {
        override fun shouldBlockRequest(r: CefriumBrowser.ResourceRequest): Boolean {
            if (r.isMainFrame) return false
            val u = r.url ?: return false
            if (!u.startsWith("http")) return false
            return model.shouldBlockRequest(t, u, CefriumEngine.kindOf(r), false)
        }
    }

    private class Nav(private val t: Tab, private val model: BrowserModel) : CefriumNavigationClient {
        override fun onBeforeNavigate(browser: CefriumBrowser, request: CefriumNavigationRequest): Boolean {
            val u = request.url ?: return false
            // Cefrium cannot tell which link a tap landed on, so a tap on an
            // ad is stopped rather than trusted (the model gets no host)
            return model.shouldOverrideNavigation(t, u, request.isForMainFrame, request.hasGesture(), request.isRedirect, null)
        }

        override fun onLoadStart(browser: CefriumBrowser, url: String) {
            model.onPageStarted(t, url)
        }

        override fun onUrlChanged(browser: CefriumBrowser, url: String) {
            model.onUrlChanged(t, url)
        }

        override fun onDocumentAvailable(browser: CefriumBrowser) {
            model.onPageCommitVisible(t, browser.url ?: t.top)
        }

        override fun onProgressChanged(browser: CefriumBrowser, percent: Int) {
            model.onProgress(t, percent)
        }

        override fun onLoadingStateChanged(browser: CefriumBrowser, loading: Boolean, canGoBack: Boolean, canGoForward: Boolean) {
            if (!loading) model.onPageFinished(t, browser.url ?: t.top)
        }

        override fun onLoadError(browser: CefriumBrowser, error: CefriumLoadError) {
            // the WebView build shows the engine's own error page too; nothing to do here
        }

        override fun onRenderProcessTerminated(browser: CefriumBrowser, status: CefriumRendererTerminationStatus, errorCode: Int) {
            model.onRendererGone(t)
        }

        // a certificate that fails: that site opens in the sandbox, without asking
        override fun onSslError(browser: CefriumBrowser, error: com.cefrium.CefriumSslError, callback: CefriumBrowser.SslErrorCallback) {
            callback.cancel()
            model.onSslError(t, error.url)
        }
    }

    private class Chrome(private val t: Tab, private val model: BrowserModel, private val page: CefriumPage) : CefriumChromeClient {
        override fun onTitleChanged(browser: CefriumBrowser, title: String?) {
            model.onTitle(t, title ?: "")
        }

        override fun onFullscreenChanged(browser: CefriumBrowser, fullscreen: Boolean) {
            if (fullscreen) {
                // the page's own view fills the screen; leaving it asks the
                // page to leave full screen, and the engine reports back
                model.onFullscreen(t, page.view) { page.evaluateJavascript("document.exitFullscreen()") }
            } else {
                model.onFullscreen(t, null) {}
            }
        }

        // New tabs and pop-ups. Only from a tap: a page cannot open one by
        // itself. A tapped link to an ad opens nothing; another link opens as
        // a tab. A script's window is made hidden and shown only once its
        // first address is known to be the same site or a sign-in, so ads
        // that open in a new tab never appear.
        override fun onCreateWindow(browser: CefriumBrowser, popup: CefriumBrowser, url: String?, userGesture: Boolean): Boolean {
            if (!userGesture) return false
            if (url != null && url.startsWith("http")) {
                if (model.isAd(t, url)) { model.onBlocked(t); return false }
                model.newTab(url, t.container, after = t)
                return false
            }
            val nt = model.newHeldTab(t) ?: return false
            val w = CefriumEngine.wrap(nt, model, popup)
            nt.web = w
            model.schedulePopupTimeout(nt, t)
            return true
        }

        override fun onCloseWindow(browser: CefriumBrowser, popup: CefriumBrowser) {
            CefriumEngine.pages[popup]?.let { model.closeWindow(it) }
        }

        override fun onContextMenu(browser: CefriumBrowser, menu: CefriumContextMenu): Boolean {
            val link = menu.linkUrl ?: ""
            val image = menu.sourceUrl ?: ""
            if (link.isEmpty() && image.isEmpty()) return false // text: the engine's own selection menu
            menu.cancel()
            model.onLongPress(t, link.ifEmpty { null }, image.ifEmpty { null })
            return true
        }

        override fun onShowFileChooser(browser: CefriumBrowser, params: CefriumFileChooserParams, callback: CefriumFileChooserCallback): Boolean {
            model.onFileChooser(t, FileRequest(
                createIntent = { runCatching { params.createIntent() }.getOrNull() },
                parseResult = { code, data -> CefriumFileChooserParams.parseResult(code, data)?.map { Uri.parse(it) }?.toTypedArray() },
                answer = { uris ->
                    if (uris == null) callback.cancel()
                    else callback.select(uris.map { it.toString() }.toTypedArray())
                },
            ))
            return true
        }

        override fun onPermissionRequest(browser: CefriumBrowser, request: CefriumPermissionRequest) {
            // calls (WebRTC): the camera and microphone, which Android lets
            // Iris use once you allow it (the activity asks). Cefrium grants
            // all or nothing, so a page that asked for more than Android
            // allowed gets nothing rather than a grant it cannot keep.
            // Protected video (DRM) needs no prompt here: Chromium handles it.
            val asked = request.permissions.mapNotNull {
                when (it) {
                    CefriumPermission.CAMERA -> PagePermission.CAMERA
                    CefriumPermission.MICROPHONE -> PagePermission.MICROPHONE
                    else -> null
                }
            }
            if (asked.isEmpty()) {
                request.deny()
                return
            }
            model.onMediaRequest(t, MediaRequest(
                resources = asked,
                grant = { granted -> if (granted.containsAll(asked)) request.grant() else request.deny() },
                deny = { request.deny() },
            ))
        }
    }

    /** downloads go to the phone's Downloads folder, through Iris's downloads manager */
    private class Downloads(private val t: Tab, private val model: BrowserModel) : CefriumBrowser.CefriumDownloadHandler {
        override fun onBeforeDownload(item: CefriumBrowser.DownloadItem, callback: CefriumBrowser.BeforeDownloadCallback) {
            val u = item.url ?: ""
            val name = (item.suggestedName ?: "").ifEmpty { "download" }
            if (!u.startsWith("http")) {
                callback.allow(null) // a file the page made (blob:, data:): saved by the engine
                Toast.makeText(IrisApp.instance, "Downloading $name", Toast.LENGTH_SHORT).show()
                return
            }
            callback.cancel()
            // the tab's own profile's cookies go along, so downloads behind a sign-in work
            val profile = CefriumEngine.profileOf(t)
            profile.cookieManager.getCookie(u) { c ->
                CefriumEngine.ui.post {
                    model.onDownload(t, u, model.engine.mobileAgent(), null, item.mimeType, item.totalBytes, c, name)
                }
            }
        }

        override fun onDownloadUpdated(item: CefriumBrowser.DownloadItem) {}
    }
}
