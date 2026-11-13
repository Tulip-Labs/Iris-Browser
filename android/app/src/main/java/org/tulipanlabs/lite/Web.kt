// SPDX-License-Identifier: GPL-3.0-only
package org.tulipanlabs.lite

import android.annotation.SuppressLint
import android.app.DownloadManager
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.os.Environment
import android.os.Message
import android.view.View
import android.webkit.CookieManager
import android.webkit.PermissionRequest
import android.webkit.RenderProcessGoneDetail
import android.webkit.URLUtil
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import java.io.ByteArrayInputStream
import java.security.SecureRandom

// A tab and its page: Android's own WebView (Chromium, kept up to date by the
// system), with Lite Shields between the page and the network.

class Tab(val id: Long, val private: Boolean) {
    var url = ""
    var title = ""
    var web: WebView? = null
    var saved: Bundle? = null // the page's history while its WebView is put away to save memory
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
    fun onNewTab(from: Tab, url: String, transport: Message?)
    fun onFullscreen(view: View?, done: WebChromeClient.CustomViewCallback?)
    fun onCrashed(t: Tab)
    fun onFileChooser(cb: ValueCallback<Array<Uri>>, params: WebChromeClient.FileChooserParams): Boolean
    fun onLongPress(t: Tab, link: String, image: String)
}

class Pages(private val ctx: Context, private val set: Settings, private val events: PageEvents) {
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

    private val docStart = WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)

    @SuppressLint("SetJavaScriptEnabled")
    fun make(t: Tab): WebView {
        val w = WebView(ctx)
        t.web = w
        w.setBackgroundColor(Color.WHITE)
        val s = w.settings
        s.javaScriptEnabled = true
        s.domStorageEnabled = true
        s.databaseEnabled = true
        s.loadWithOverviewMode = true
        s.useWideViewPort = true
        s.setSupportZoom(true)
        s.builtInZoomControls = true
        s.displayZoomControls = false
        s.mediaPlaybackRequiresUserGesture = true
        s.setSupportMultipleWindows(true)
        s.javaScriptCanOpenWindowsAutomatically = false
        s.mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
        s.allowFileAccess = false
        s.allowContentAccess = false
        s.safeBrowsingEnabled = false // Lite Shields does this job without sending addresses away
        if (set.desktop) s.userAgentString = desktopAgent(s.userAgentString)
        if (t.private) {
            s.cacheMode = WebSettings.LOAD_NO_CACHE
            s.saveFormData = false
        }
        CookieManager.getInstance().setAcceptThirdPartyCookies(w, false)
        if (docStart) {
            for (js in scripts()) {
                try { WebViewCompat.addDocumentStartJavaScript(w, js, setOf("*")) } catch (e: Exception) {}
            }
        }
        w.webViewClient = Client(t)
        w.webChromeClient = Chrome(t)
        w.setDownloadListener { u, agent, disposition, mime, _ -> download(u, agent, disposition, mime) }
        w.setOnLongClickListener {
            val h = w.hitTestResult
            when (h.type) {
                WebView.HitTestResult.SRC_ANCHOR_TYPE -> { events.onLongPress(t, h.extra ?: "", ""); true }
                WebView.HitTestResult.SRC_IMAGE_ANCHOR_TYPE -> {
                    val msg = w.handler.obtainMessage()
                    w.requestFocusNodeHref(msg)
                    val link = msg.data.getString("url") ?: ""
                    events.onLongPress(t, link, h.extra ?: ""); true
                }
                WebView.HitTestResult.IMAGE_TYPE -> { events.onLongPress(t, "", h.extra ?: ""); true }
                else -> false
            }
        }
        return w
    }

    fun desktopAgent(ua: String): String =
        ua.replace(Regex("\\(Linux; Android [^)]*\\)"), "(X11; Linux x86_64)").replace(" Mobile", "").replace("; wv", "")

    private fun download(u: String, agent: String, disposition: String?, mime: String?) {
        // Android 8 and 9 ask for storage access before saving into Downloads
        if (android.os.Build.VERSION.SDK_INT < 29 &&
            ctx.checkSelfPermission(android.Manifest.permission.WRITE_EXTERNAL_STORAGE) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            (ctx as? android.app.Activity)?.requestPermissions(arrayOf(android.Manifest.permission.WRITE_EXTERNAL_STORAGE), 9)
            android.widget.Toast.makeText(ctx, "Allow storage, then tap the download again", android.widget.Toast.LENGTH_LONG).show()
            return
        }
        try {
            val name = URLUtil.guessFileName(u, disposition, mime)
            val r = DownloadManager.Request(Uri.parse(u))
            r.setMimeType(mime)
            CookieManager.getInstance().getCookie(u)?.let { r.addRequestHeader("Cookie", it) }
            r.addRequestHeader("User-Agent", agent)
            r.setTitle(name)
            r.setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
            r.setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, name)
            (ctx.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager).enqueue(r)
            android.widget.Toast.makeText(ctx, "Downloading $name", android.widget.Toast.LENGTH_SHORT).show()
        } catch (e: Exception) {
            android.widget.Toast.makeText(ctx, "This download could not start", android.widget.Toast.LENGTH_SHORT).show()
        }
    }

    fun shieldOn(page: String): Boolean = set.shields && hostOf(page).removePrefix("www.") !in set.shieldOff

    /** The style sheet that hides what ads leave behind on this page. */
    fun hide(w: WebView, page: String) {
        if (!shieldOn(page) || !page.startsWith("http")) return
        val e = shields ?: return
        val host = hostOf(page)
        val css = cssCache[host] ?: e.hidingCSS(page).also { cssCache[host] = it }
        if (css.isEmpty()) return
        val js = "(() => { const add = () => { let s = document.getElementById('lite-shields'); if (!s) { s = document.createElement('style'); " +
            "s.id = 'lite-shields'; (document.head || document.documentElement).appendChild(s); } if (!s.textContent) s.textContent = " +
            org.json.JSONObject.quote(css) + "; }; if (document.documentElement) add(); else document.addEventListener('DOMContentLoaded', add); })();"
        w.evaluateJavascript(js, null)
    }

    fun clearCache() = synchronized(cssCache) { cssCache.clear() }

    private fun kindOf(r: WebResourceRequest): Int {
        val p = (r.url.path ?: "").lowercase()
        val acc = r.requestHeaders?.get("Accept") ?: ""
        return when {
            p.endsWith(".css") || acc.startsWith("text/css") -> Kind.STYLESHEET
            p.endsWith(".woff") || p.endsWith(".woff2") || p.endsWith(".ttf") || p.endsWith(".otf") -> Kind.FONT
            p.endsWith(".js") || p.endsWith(".mjs") -> Kind.SCRIPT
            acc.startsWith("image/") || listOf(".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".avif", ".ico").any { p.endsWith(it) } -> Kind.IMAGE
            listOf(".mp4", ".webm", ".m3u8", ".mp3", ".m4s").any { p.endsWith(it) } -> Kind.MEDIA
            acc.contains("application/json") -> Kind.XHR
            acc.startsWith("text/html") -> Kind.SUBDOCUMENT
            else -> Kind.OTHER
        }
    }

    private val empty get() = WebResourceResponse("text/plain", "utf-8", 403, "Blocked", HashMap(), ByteArrayInputStream(ByteArray(0)))

    inner class Client(private val t: Tab) : WebViewClient() {
        override fun shouldOverrideUrlLoading(v: WebView, r: WebResourceRequest): Boolean {
            val u = r.url.toString()
            val s = u.lowercase()
            if (!s.startsWith("http:") && !s.startsWith("https:") && !s.startsWith("about:") && !s.startsWith("data:") && !s.startsWith("blob:")) {
                // another app's link (intent:, tel:, mailto:, market:, whatsapp:)
                try {
                    val i = if (s.startsWith("intent:")) Intent.parseUri(u, Intent.URI_INTENT_SCHEME) else Intent(Intent.ACTION_VIEW, Uri.parse(u))
                    i.addCategory(Intent.CATEGORY_BROWSABLE)
                    i.component = null
                    i.selector = null
                    ctx.startActivity(i)
                } catch (e: Exception) {
                    // an intent: link with a web fallback opens that instead
                    if (s.startsWith("intent:")) {
                        val fb = Regex("S\\.browser_fallback_url=([^;]+)").find(u)?.groupValues?.get(1)
                        if (fb != null) v.loadUrl(Uri.decode(fb))
                    }
                }
                return true
            }
            if (!r.isForMainFrame) return false
            // HTTPS-only: try the secure address first
            if (set.httpsOnly && s.startsWith("http://") && hostOf(u) !in insecureOK) {
                upgraded.add(hostOf(u))
                v.loadUrl("https://" + u.substring(7))
                return true
            }
            if (set.shields && set.cleanLinks) {
                val c = Links.clean(u)
                if (c != u) {
                    v.loadUrl(c)
                    return true
                }
            }
            return false
        }

        override fun onPageStarted(v: WebView, u: String, icon: Bitmap?) {
            t.page = u
            t.blocked = 0
            events.onUrl(t, u)
            events.onProgress(t, 5)
            if (!docStart) for (js in scripts()) v.evaluateJavascript(js, null)
        }

        override fun onPageCommitVisible(v: WebView, u: String) = hide(v, u)

        override fun onPageFinished(v: WebView, u: String) {
            hide(v, u)
            t.canBack = v.canGoBack()
            t.canForward = v.canGoForward()
            events.onProgress(t, 100)
        }

        override fun doUpdateVisitedHistory(v: WebView, u: String, reload: Boolean) {
            t.page = u
            t.canBack = v.canGoBack()
            t.canForward = v.canGoForward()
            events.onUrl(t, u)
        }

        override fun shouldInterceptRequest(v: WebView, r: WebResourceRequest): WebResourceResponse? {
            if (r.isForMainFrame) return null
            val u = r.url.toString()
            if (!u.startsWith("http")) return null
            val page = t.page
            if (!shieldOn(page)) return null
            val kind = kindOf(r)
            if (kind == Kind.STYLESHEET || kind == Kind.FONT) return null // never: pages must look right
            val e = shields
            val host = hostOf(u)
            val third = siteOf(host) != siteOf(hostOf(page))
            val block = if (e != null) {
                e.blocked(u, page, kind) || (third && BuiltIn.blocked(host) && !e.excepted(u, page, kind))
            } else third && BuiltIn.blocked(host)
            if (!block) return null
            v.post { events.onBlocked(t) }
            return empty
        }

        override fun onReceivedError(v: WebView, r: WebResourceRequest, e: WebResourceError) {
            // HTTPS-only: a site with no secure version opens over http, once asked
            if (r.isForMainFrame && r.url.scheme == "https") {
                val h = r.url.host ?: return
                if (h in upgraded && h !in insecureOK) {
                    insecureOK.add(h)
                    v.loadUrl("http://" + r.url.toString().substring(8))
                }
            }
        }

        override fun onRenderProcessGone(v: WebView, d: RenderProcessGoneDetail): Boolean {
            // the page's process ended (out of memory, or crashed): the tab offers a reload
            (v.parent as? android.view.ViewGroup)?.removeView(v)
            v.destroy()
            t.web = null
            events.onCrashed(t)
            return true
        }
    }

    inner class Chrome(private val t: Tab) : WebChromeClient() {
        override fun onProgressChanged(v: WebView, p: Int) = events.onProgress(t, p)

        override fun onReceivedTitle(v: WebView, title: String?) = events.onTitle(t, title ?: "")

        override fun onCreateWindow(v: WebView, dialog: Boolean, gesture: Boolean, msg: Message): Boolean {
            if (!gesture) return false // no popups the person did not ask for
            val h = v.hitTestResult
            events.onNewTab(t, h.extra ?: "", msg)
            return true
        }

        override fun onShowCustomView(view: View, cb: CustomViewCallback) = events.onFullscreen(view, cb)

        override fun onHideCustomView() = events.onFullscreen(null, null)

        override fun getDefaultVideoPoster(): Bitmap = Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888)

        override fun onShowFileChooser(v: WebView, cb: ValueCallback<Array<Uri>>, params: FileChooserParams): Boolean =
            events.onFileChooser(cb, params)

        override fun onPermissionRequest(r: PermissionRequest) = r.deny() // camera and microphone stay off
    }
}
