// SPDX-License-Identifier: GPL-3.0-only
package org.tulipanlabs.lite

import android.annotation.SuppressLint
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import org.json.JSONObject

// Lite results, as on the desktop: a Google search is read by a hidden page
// and shown on Lite's own page, in the palette, without ads or clutter. The
// scripts that read Google's page are the desktop's own (assets/js/google-*.js).

class WebHit(val title: String, val url: String, val snippet: String, val site: String)
class ImageHit(val src: String, val page: String)

class Results(private val ctx: Context) {
    private val ui = Handler(Looper.getMainLooper())
    private var worker: WebView? = null
    private var seq = 0

    private fun asset(name: String) = try {
        ctx.assets.open("js/$name").bufferedReader().use { it.readText() }
    } catch (e: Exception) {
        ""
    }

    private val webJs by lazy { asset("google-web.js") }
    private val imagesJs by lazy { asset("google-images.js") }

    /**
     * Reads the web results and the pictures for q. The hidden page sits,
     * invisible, in host (Google lays out its page only for a page with a
     * size). done gets null when Google asked for a human check or did not
     * answer in time: the caller then shows Google's own page.
     */
    @SuppressLint("SetJavaScriptEnabled")
    fun fetch(host: ViewGroup, q: String, done: (List<WebHit>?, List<ImageHit>) -> Unit) {
        val my = ++seq
        val w = worker ?: WebView(ctx).also { v ->
            v.settings.javaScriptEnabled = true
            v.settings.domStorageEnabled = true
            v.visibility = View.INVISIBLE
            host.addView(v, 0, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
            worker = v
        }
        if (w.parent !== host) {
            (w.parent as? ViewGroup)?.removeView(w)
            host.addView(w, 0, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        }
        var web: List<WebHit>? = null
        var finished = false
        var stage = 0
        var tries = 0
        lateinit var again: (String?) -> Unit
        fun finish(hits: List<WebHit>?, images: List<ImageHit>) {
            if (finished || my != seq) return
            finished = true
            w.stopLoading()
            done(hits, images)
        }
        ui.postDelayed({
            if (!finished && my == seq) android.util.Log.i("LiteResults", "timed out at stage $stage")
            finish(web, emptyList())
        }, 15000)

        // first the links, then the pictures
        w.webViewClient = object : WebViewClient() {
            override fun onPageFinished(v: WebView, url: String) {
                if (my != seq || finished) return
                val st = stage
                ui.postDelayed({
                    if (my != seq || finished || st != stage) return@postDelayed
                    if (stage == 0) {
                        v.evaluateJavascript(webJs) { raw ->
                            val (hits, captcha) = parseWeb(raw)
                            android.util.Log.i("LiteResults", "web: ${hits.size} links, captcha $captcha, at $url")
                            if (hits.isEmpty() && tries == 0 && (ctx.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0) {
                                // what the page holds, for the screenshot run's log
                                v.evaluateJavascript(DIAG) { d -> (d ?: "").chunked(900).forEach { android.util.Log.i("LiteResults", "diag: $it") } }
                            }
                            if (hits.isEmpty() && !captcha && tries++ < 3) {
                                // the page may still be building its results: look again
                                ui.postDelayed({ if (my == seq && !finished) v.evaluateJavascript(webJs) { r2 -> again(r2) } }, 700)
                                return@evaluateJavascript
                            }
                            if (captcha || hits.isEmpty()) {
                                finish(null, emptyList())
                                return@evaluateJavascript
                            }
                            web = hits
                            stage = 1
                            v.loadUrl(Search.url(q, Mode.IMAGES))
                        }
                    } else {
                        v.evaluateJavascript(imagesJs) { raw ->
                            val im = parseImages(raw)
                            android.util.Log.i("LiteResults", "images: ${im.size}")
                            finish(web, im)
                        }
                    }
                }, if (st == 0) 250 else 900)
            }
        }
        again = { raw ->
            val (hits, captcha) = parseWeb(raw)
            android.util.Log.i("LiteResults", "web again: ${hits.size} links, captcha $captcha")
            when {
                hits.isNotEmpty() -> {
                    web = hits
                    stage = 1
                    w.loadUrl(Search.url(q, Mode.IMAGES))
                }
                captcha || tries++ >= 3 -> finish(null, emptyList())
                else -> ui.postDelayed({ if (my == seq && !finished) w.evaluateJavascript(webJs) { r -> again(r) } }, 700)
            }
        }
        w.loadUrl(Search.url(q, Mode.WEB))
    }

    fun cancel() {
        seq++
        worker?.stopLoading()
    }

    private fun parseWeb(raw: String?): Pair<List<WebHit>, Boolean> = try {
        val o = JSONObject(raw ?: "null")
        val a = o.optJSONArray("web")
        val out = ArrayList<WebHit>()
        if (a != null) for (i in 0 until a.length()) {
            val h = a.getJSONObject(i)
            val url = h.optString("u")
            val title = h.optString("t").trim()
            if (title.isEmpty() || !url.startsWith("http")) continue
            var snip = h.optString("s").trim()
            if (snip == title) snip = ""
            val site = h.optString("site").ifEmpty { hostOf(url).removePrefix("www.") }
            out.add(WebHit(title, url, snip, site))
        }
        Pair(out, o.optBoolean("captcha"))
    } catch (e: Exception) {
        Pair(emptyList(), false)
    }

    private fun parseImages(raw: String?): List<ImageHit> = try {
        val a = JSONObject(raw ?: "null").optJSONArray("images")
        val out = ArrayList<ImageHit>()
        if (a != null) for (i in 0 until minOf(a.length(), 16)) {
            val h = a.getJSONObject(i)
            val src = h.optString("src")
            if (src.startsWith("data:image/") || src.startsWith("https://")) out.add(ImageHit(src, h.optString("page")))
        }
        out
    } catch (e: Exception) {
        emptyList()
    }

    companion object {
        private const val DIAG = "JSON.stringify({rso:!!document.querySelector('#rso'),a:document.querySelectorAll('a[href]').length,h3:document.querySelectorAll('h3').length,head:document.querySelectorAll('[role=heading]').length,it:(document.body.innerText||'').length,tc:document.body.textContent.length,title:document.title,sample:[...document.querySelectorAll('a[href]')].slice(0,30).map(a=>a.href.slice(0,70)+' :: '+(a.innerText||'').slice(0,70).replace(/\\n/g,'|'))})"

        const val DESKTOP_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"

        private fun esc(s: String) = s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;").replace("'", "&#39;")

        private fun css(c: Int) = String.format("#%06x", c and 0xffffff)

        /** the page itself: plain HTML in the palette, no script */
        fun page(q: String, web: List<WebHit>, images: List<ImageHit>, p: Palette): String {
            val bg = if (p.grad != null) "linear-gradient(180deg,${p.grad.joinToString(",") { css(Palette.mix(it, Palette.WHITE, 0.55f)) }}) fixed" else css(p.surface)
            val chip = { label: String, href: String, on: Boolean ->
                "<a class=\"chip${if (on) " on" else ""}\" href=\"${esc(href)}\">${esc(label)}</a>"
            }
            val b = StringBuilder()
            b.append("<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">")
            b.append("<title>").append(esc(q)).append(" · Lite</title><style>")
            b.append(":root{--ink:${css(p.onSurface)};--ink2:${css(p.onSurfaceVariant)};--pri:${css(p.primary)};--card:${css(if (p.dark) p.surfaceHigh else Palette.WHITE)};--line:${css(p.outlineVariant)};--chip:${css(p.primaryContainer)};--onchip:${css(p.onPrimaryContainer)}}")
            b.append("*{box-sizing:border-box}html,body{margin:0}body{font:16px/1.45 system-ui,Roboto,sans-serif;color:var(--ink);background:$bg;min-height:100vh}")
            b.append("main{max-width:760px;margin:0 auto;padding:14px 14px 40px}")
            b.append("h1{font-size:20px;margin:4px 4px 12px;font-weight:600;overflow-wrap:anywhere}")
            b.append(".chips{display:flex;gap:8px;overflow-x:auto;padding:0 2px 12px;scrollbar-width:none}.chips::-webkit-scrollbar{display:none}")
            b.append(".chip{flex:none;padding:8px 14px;border-radius:999px;border:1px solid var(--line);color:var(--ink);text-decoration:none;font-size:14px;font-weight:600;background:var(--card)}")
            b.append(".chip.on{background:var(--chip);color:var(--onchip);border-color:transparent}")
            b.append(".pics{display:flex;gap:8px;overflow-x:auto;padding:2px 2px 14px;scrollbar-width:none}.pics::-webkit-scrollbar{display:none}")
            b.append(".pics a{flex:none;width:132px;height:100px;border-radius:16px;overflow:hidden;background:var(--line)}.pics img{width:100%;height:100%;object-fit:cover;display:block}")
            b.append(".r{display:block;background:var(--card);border-radius:20px;padding:14px 16px;margin:0 0 10px;text-decoration:none;color:inherit;box-shadow:0 1px 2px rgba(0,0,0,.06)}")
            b.append(".r:active{opacity:.75}.site{display:flex;align-items:center;gap:8px;font-size:13px;color:var(--ink2);margin-bottom:4px}")
            b.append(".mono{width:22px;height:22px;border-radius:7px;display:grid;place-items:center;color:#fff;font-size:11px;font-weight:700;flex:none}")
            b.append(".t{font-size:17px;font-weight:600;color:var(--pri);margin:0 0 4px;overflow-wrap:anywhere}.s{font-size:14px;color:var(--ink2);margin:0}")
            b.append(".foot{text-align:center;margin-top:18px}.foot a{color:var(--pri);font-weight:600;text-decoration:none}")
            b.append("@media(min-width:900px){main{max-width:1000px}.grid{display:grid;grid-template-columns:1fr 1fr;gap:10px}.grid .r{margin:0}}")
            b.append("</style></head><body><main>")
            b.append("<h1>").append(esc(q)).append("</h1><nav class=\"chips\">")
            b.append(chip("Web", Search.url(q, Mode.WEB), true))
            b.append(chip("AI Mode", Search.url(q, Mode.AI), false))
            b.append(chip("Images", Search.url(q, Mode.IMAGES), false))
            b.append(chip("Videos", Search.url(q, Mode.VIDEOS), false))
            b.append(chip("YouTube", Search.url(q, Mode.YOUTUBE), false))
            b.append("</nav>")
            if (images.isNotEmpty()) {
                b.append("<div class=\"pics\">")
                for (im in images) {
                    val href = if (im.page.startsWith("http")) im.page else Search.url(q, Mode.IMAGES)
                    b.append("<a href=\"${esc(href)}\"><img loading=\"lazy\" alt=\"\" src=\"${esc(im.src)}\"></a>")
                }
                b.append("</div>")
            }
            b.append("<div class=\"grid\">")
            for (h in web) {
                val host = hostOf(h.url)
                b.append("<a class=\"r\" href=\"${esc(h.url)}\"><div class=\"site\"><span class=\"mono\" style=\"background:${css(siteColor(host))}\">${esc(monogram(host))}</span>${esc(h.site)}</div>")
                b.append("<p class=\"t\">${esc(h.title)}</p>")
                if (h.snippet.isNotEmpty()) b.append("<p class=\"s\">${esc(h.snippet)}</p>")
                b.append("</a>")
            }
            b.append("</div><p class=\"foot\"><a href=\"${esc(Search.url(q, Mode.WEB).replace("&udm=14", ""))}\">See this search on Google</a></p>")
            b.append("</main></body></html>")
            return b.toString()
        }
    }
}
