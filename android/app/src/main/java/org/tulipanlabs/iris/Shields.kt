package org.tulipanlabs.iris

import android.content.Context
import android.webkit.WebResourceResponse
import org.json.JSONArray
import java.io.ByteArrayInputStream
import java.util.zip.GZIPInputStream
import kotlin.concurrent.thread

/**
 * Iris Shields: requests to about 100,000 ad and tracker domains (the list
 * Iris for Linux uses) are answered with nothing, before they leave the
 * phone; third-party cookies are refused. Off per site, or everywhere.
 */
object Shields {
    @Volatile private var blocked: Set<String> = emptySet()

    /** messaging, sign-in and human checks: never blocked */
    private val never = listOf("whatsapp.com", "whatsapp.net", "accounts.google.com", "login.microsoftonline.com",
        "login.live.com", "teams.microsoft.com", "meet.google.com", "challenges.cloudflare.com", "hcaptcha.com",
        "recaptcha.net", "appleid.apple.com")

    /** delivery networks that carry ordinary sites: an entry naming one whole is dropped */
    private val shared = setOf("cloudfront.net", "amazonaws.com", "akamaihd.net", "akamaized.net", "akamai.net",
        "fastly.net", "azureedge.net", "googleusercontent.com", "googleapis.com", "gstatic.com", "cloudflare.com",
        "jsdelivr.net", "unpkg.com", "github.io", "githubusercontent.com", "netlify.app", "vercel.app", "wp.com",
        "cloudinary.com", "imgix.net", "ctfassets.net", "shopifycdn.com", "myshopify.com", "wixstatic.com")

    fun load(c: Context) = thread(name = "shields") {
        runCatching {
            val text = GZIPInputStream(c.assets.open("shield-domains.json.gz")).bufferedReader().use { it.readText() }
            val a = JSONArray(text)
            val s = HashSet<String>(a.length() * 2)
            for (i in 0 until a.length()) {
                val d = a.getString(i)
                if (d.contains('.') && d !in shared && never.none { d == it || d.endsWith(".$it") || it.endsWith(".$d") }) s.add(d)
            }
            blocked = s
        }
    }

    fun isBlocked(host: String): Boolean {
        var h = host
        while (true) {
            if (h in blocked) return true
            val dot = h.indexOf('.')
            if (dot < 0) return false
            h = h.substring(dot + 1)
            if (!h.contains('.')) return false
        }
    }

    /** whether Shields guard this page's site */
    fun onFor(pageUrl: String): Boolean {
        if (!Store.shields) return false
        val h = Search.host(pageUrl) ?: return true
        return Search.site(h) !in Store.shieldsOff
    }

    private val empty get() = WebResourceResponse("text/plain", "utf-8", 204, "No Content", emptyMap(), ByteArrayInputStream(ByteArray(0)))

    /** what to answer a request of a page instead of the network (null: let it go) */
    fun intercept(pageUrl: String, url: String): WebResourceResponse? {
        if (!onFor(pageUrl)) return null
        val host = Search.host(url) ?: return null
        val page = Search.host(pageUrl)
        // the site's own requests always go
        if (page != null && Search.site(page) == Search.site(host)) return null
        return if (isBlocked(host)) empty else null
    }
}
