package org.tulipanlabs.iris

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.net.http.SslError
import android.os.Bundle
import android.os.Process
import android.webkit.CookieManager
import android.webkit.GeolocationPermissions
import android.webkit.PermissionRequest
import android.webkit.SslErrorHandler
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebStorage
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import org.tulipanlabs.iris.ui.GlassButton
import org.tulipanlabs.iris.ui.Glyph
import org.tulipanlabs.iris.ui.GlyphIcon
import org.tulipanlabs.iris.ui.IrisTheme
import org.tulipanlabs.iris.ui.LocalPalette
import org.tulipanlabs.iris.ui.ProgressLine
import org.tulipanlabs.iris.ui.Txt
import org.tulipanlabs.iris.ui.glass
import java.io.ByteArrayInputStream
import java.io.File

/**
 * The sandbox, for sites Iris does not trust (Search.untrusted, or a
 * certificate that fails). Nothing is asked: such a site simply opens here.
 *
 * - A process of its own (":sandbox"), so its WebView, its page process and
 *   its memory are never those of your other tabs.
 * - WebView data of its own, wiped when the sandbox starts and when it
 *   closes: no cookie, storage, cache or sign-in of yours, and nothing it
 *   sets survives.
 * - Less to attack: no files, camera, microphone, location, pop-ups or
 *   downloads; Safe Browsing on; Shields on.
 * - A trusted site you go to from here opens back in Iris.
 */
class SandboxActivity : ComponentActivity() {
    private var web: WebView? = null
    private var url by mutableStateOf("")
    private var loadProgress by mutableIntStateOf(0)
    private var note by mutableStateOf<String?>(null)
    /** the host whose failing certificate this sandbox was opened for */
    private var certHost: String? = null

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val start = intent.getStringExtra(EXTRA_URL) ?: run { finish(); return }
        certHost = if (intent.getBooleanExtra(EXTRA_CERT, false)) Search.host(start) else null
        url = start
        val w = WebView(this)
        web = w
        w.setBackgroundColor(Color.WHITE)
        val s = w.settings
        s.javaScriptEnabled = true
        s.domStorageEnabled = true
        s.loadWithOverviewMode = true
        s.useWideViewPort = true
        s.setSupportZoom(true)
        s.builtInZoomControls = true
        s.displayZoomControls = false
        s.setSupportMultipleWindows(false)
        s.javaScriptCanOpenWindowsAutomatically = false
        s.mediaPlaybackRequiresUserGesture = true
        s.mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
        s.allowFileAccess = false
        s.allowContentAccess = false
        s.setGeolocationEnabled(false)
        s.safeBrowsingEnabled = true
        s.cacheMode = WebSettings.LOAD_NO_CACHE
        CookieManager.getInstance().setAcceptThirdPartyCookies(w, false)
        w.webViewClient = Client()
        w.webChromeClient = object : WebChromeClient() {
            override fun onProgressChanged(view: WebView, newProgress: Int) { loadProgress = newProgress }
            override fun onPermissionRequest(request: PermissionRequest) = request.deny()
            override fun onGeolocationPermissionsShowPrompt(origin: String, callback: GeolocationPermissions.Callback) = callback.invoke(origin, false, false)
        }
        w.setDownloadListener { _, _, _, _, _ -> note = "Downloads are off in the sandbox" }
        w.loadUrl(start)
        setContent { IrisTheme(false) { Screen(w) } }
    }

    @androidx.compose.runtime.Composable
    private fun Screen(w: WebView) {
        val p = LocalPalette.current
        val orange = androidx.compose.ui.graphics.Color(0xFFE8890A)
        Box(Modifier.fillMaxSize().background(Brush.verticalGradient(p.back))) {
            Column(Modifier.fillMaxSize()) {
                Row(
                    Modifier.statusBarsPadding().padding(10.dp).fillMaxWidth()
                        .glass(p, RoundedCornerShape(50), elevation = 6.dp).padding(start = 14.dp, end = 4.dp, top = 4.dp, bottom = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    GlyphIcon(Glyph.SHIELD, size = 18.dp, tint = orange)
                    Spacer(Modifier.width(8.dp))
                    Column(Modifier.weight(1f)) {
                        Txt("Sandbox", size = 12.sp, weight = FontWeight.SemiBold, color = orange)
                        Txt(Search.display(url), size = 14.sp, maxLines = 1)
                    }
                    GlassButton(Glyph.RELOAD, "Reload", { w.reload() }, size = 38.dp, clear = true)
                    GlassButton(Glyph.CLOSE, "Close the sandbox", { finish() }, size = 38.dp, clear = true)
                }
                if (loadProgress in 1..99) ProgressLine(loadProgress / 100f)
                Box(Modifier.weight(1f).fillMaxWidth().padding(horizontal = 6.dp).clip(RoundedCornerShape(20.dp))) {
                    AndroidView(factory = { w }, modifier = Modifier.fillMaxSize())
                }
                Row(
                    Modifier.navigationBarsPadding().padding(10.dp).fillMaxWidth(),
                    horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically,
                ) {
                    Txt(note ?: "This site is not secure, so Iris opened it here: it sees nothing of yours, and nothing it keeps stays.",
                        size = 12.sp, color = p.ink2)
                }
            }
            BackHandler { if (w.canGoBack()) w.goBack() else finish() }
        }
    }

    private inner class Client : WebViewClient() {
        override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
            if (request.isForMainFrame) return null
            val u = request.url.toString()
            if (!Shields.core.blocks(u, url, Kind.OTHER, false)) return null
            return WebResourceResponse("text/plain", "utf-8", 204, "No Content", mapOf("Access-Control-Allow-Origin" to "*"), ByteArrayInputStream(ByteArray(0)))
        }

        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
            val u = request.url.toString()
            val scheme = request.url.scheme?.lowercase()
            if (scheme != "http" && scheme != "https") return true // no other apps from here
            if (!request.isForMainFrame) return false
            val target = Search.unwrapRedirect(u) ?: u
            // a trusted site goes back to Iris, with your tabs and sign-ins
            val stays = Search.untrusted(target) || (certHost != null && Search.host(target) == certHost)
            if (!stays) {
                startActivity(Intent(Intent.ACTION_VIEW, android.net.Uri.parse(target)).setClass(this@SandboxActivity, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                finish()
                return true
            }
            if (target != u) { view.loadUrl(target); return true }
            return false
        }

        override fun onPageStarted(view: WebView, u: String, favicon: Bitmap?) { url = u }

        @SuppressLint("WebViewClientOnReceivedSslError")
        override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, error: SslError) {
            // the one site this sandbox was opened for, despite its certificate; nothing else
            if (certHost != null && Search.host(error.url) == certHost) handler.proceed() else handler.cancel()
        }
    }

    override fun onDestroy() {
        web?.let { w ->
            (w.parent as? android.view.ViewGroup)?.removeView(w)
            w.stopLoading()
            w.destroy()
        }
        web = null
        super.onDestroy()
        if (isFinishing) {
            // everything the site kept goes, and with it this process
            runCatching { CookieManager.getInstance().removeAllCookies(null); CookieManager.getInstance().flush() }
            runCatching { WebStorage.getInstance().deleteAllData() }
            wipe(this)
            Process.killProcess(Process.myPid())
        }
    }

    companion object {
        const val PROCESS_SUFFIX = "sandbox"
        private const val EXTRA_URL = "url"
        private const val EXTRA_CERT = "cert"

        fun open(ctx: Context, url: String, cert: Boolean = false) {
            val i = Intent(ctx, SandboxActivity::class.java).putExtra(EXTRA_URL, url).putExtra(EXTRA_CERT, cert)
            if (ctx !is android.app.Activity) i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            ctx.startActivity(i)
        }

        /** the sandbox's WebView data, all of it (it is made fresh each time) */
        fun wipe(ctx: Context) {
            val base = ctx.applicationInfo.dataDir
            listOf("app_webview_$PROCESS_SUFFIX", "cache/WebView_$PROCESS_SUFFIX", "app_webview_${PROCESS_SUFFIX}_cache").forEach {
                runCatching { File(base, it).deleteRecursively() }
            }
            runCatching { File(ctx.cacheDir, "WebView").listFiles()?.filter { it.name.contains(PROCESS_SUFFIX) }?.forEach { it.deleteRecursively() } }
        }
    }
}
