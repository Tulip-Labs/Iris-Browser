package org.tulipanlabs.iris

import java.net.URI
import java.net.URLDecoder
import java.net.URLEncoder

/**
 * What the address bar does with typed text: an address opens, anything
 * else is a question for Google AI Mode, with Iris's instruction to rest the
 * answer on the best sources. "yt cats" searches YouTube. (The same rules as
 * Iris on Linux.)
 */
object Search {
    const val AI_INSTRUCTION = "Use only high-quality, authoritative and up-to-date sources (official sites, documentation, peer-reviewed research, reputable news) and cite them. Answer clearly, precisely and concisely, with the most recent information."
    private const val SEP = "\n\n"
    private val schemes = setOf("http", "https", "file", "about", "mailto", "tel")
    private val notTLD = setOf("js", "ts", "py", "kt", "java", "rs", "json", "txt", "exe", "yml", "yaml", "css", "html", "pdf", "docx", "xlsx")

    private fun enc(s: String) = URLEncoder.encode(s, "UTF-8").replace("+", "%20")

    fun aiUrl(q: String) = "https://www.google.com/search?gl=us&hl=en&udm=50&q=" + enc(q.trim() + SEP + AI_INSTRUCTION)

    /** the home of every new tab: Google AI Mode, ready for a question */
    const val HOME = "https://www.google.com/search?gl=us&hl=en&udm=50"

    /** whether an address is Google AI Mode (its page gets Iris's glass) */
    fun isAIMode(url: String): Boolean {
        val u = runCatching { URI(url) }.getOrNull() ?: return false
        val h = u.host ?: return false
        if (h != "www.google.com" && h != "google.com") return false
        return u.path == "/aimode" || (u.path == "/search" && (u.rawQuery ?: "").split('&').contains("udm=50"))
    }

    /** Google's way out to a result (google.com/url?q=…): the result itself, without the extra stop */
    fun unwrapRedirect(url: String): String? {
        val u = runCatching { URI(url) }.getOrNull() ?: return null
        val h = u.host ?: return null
        if ((h != "www.google.com" && h != "google.com") || u.path != "/url") return null
        val params = (u.rawQuery ?: return null).split('&').associate {
            it.substringBefore('=') to runCatching { URLDecoder.decode(it.substringAfter('=', ""), "UTF-8") }.getOrDefault("")
        }
        val t = params["q"] ?: params["url"] ?: return null
        return t.takeIf { it.startsWith("https://") || it.startsWith("http://") }
    }

    /**
     * Sites Iris does not trust, opened in the sandbox without asking: no
     * encryption (http), or a bare public IP. (A site whose certificate
     * fails joins them when it fails.) Your own network is trusted.
     */
    fun untrusted(url: String): Boolean {
        val u = runCatching { URI(url) }.getOrNull() ?: return false
        val scheme = u.scheme?.lowercase() ?: return false
        val host = u.host?.lowercase()?.trim('[', ']') ?: return false
        if (scheme != "http" && scheme != "https") return false
        if (isPrivateHost(host) || host.endsWith(".local") || host.endsWith(".lan") || host.endsWith(".home.arpa")) return false
        if (scheme == "http") return true
        val ipv4 = host.split('.').let { p -> p.size == 4 && p.all { it.toIntOrNull() in 0..255 } }
        return ipv4 || host.contains(':')
    }

    fun youtubeUrl(q: String) = "https://m.youtube.com/results?search_query=" + enc(q.trim())

    private fun scheme(t: String): String? {
        val i = t.indexOf(':')
        if (i <= 0) return null
        val s = t.substring(0, i)
        if (!s[0].isLetter() || !s.all { it.isLetterOrDigit() || it in "+.-" }) return null
        // "localhost:8080" is a host and a port
        val rest = t.substring(i + 1)
        val digits = rest.takeWhile { it.isDigit() }
        if (digits.isNotEmpty() && (rest.length == digits.length || rest[digits.length] in "/?#")) return null
        return s.lowercase()
    }

    fun isUrlLike(text: String): Boolean {
        val t = text.trim()
        if (t.isEmpty()) return false
        scheme(t)?.let { return it in schemes }
        if (' ' in t) return false
        val host = t.substringBefore('/').substringBefore('?').substringBefore(':').lowercase()
        if (host == "localhost") return true
        if (!host.contains('.')) return false
        val tld = host.substringAfterLast('.')
        return tld.isNotEmpty() && (tld.all { it.isDigit() } || (tld.length >= 2 && tld.all { it.isLetter() } && tld !in notTLD))
    }

    private fun isPrivateHost(h: String): Boolean {
        if (h == "localhost" || h.endsWith(".localhost")) return true
        val p = h.split('.').mapNotNull { it.toIntOrNull() }
        if (p.size != 4) return false
        return p[0] == 127 || p[0] == 10 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && p[1] in 16..31)
    }

    fun resolve(input: String): String {
        val t = input.trim()
        if (t.isEmpty()) return ""
        if (isUrlLike(t)) {
            if (scheme(t) != null) return t
            val host = t.substringBefore('/').substringBefore('?').substringBefore(':').lowercase()
            return (if (isPrivateHost(host)) "http://" else "https://") + t
        }
        if (t.lowercase().startsWith("yt ") && t.length > 3) return youtubeUrl(t.substring(3))
        return aiUrl(t)
    }

    /** the reader's words of an Iris AI search, for the address bar */
    fun query(url: String): String? {
        val u = runCatching { URI(url) }.getOrNull() ?: return null
        val host = u.host ?: return null
        if (!(host == "www.google.com" || host == "google.com") || u.path != "/search") return null
        val params = (u.rawQuery ?: return null).split('&').associate {
            it.substringBefore('=') to URLDecoder.decode(it.substringAfter('=', ""), "UTF-8")
        }
        if (params["udm"] != "50") return null
        val q = params["q"] ?: return null
        return q.substringBefore(SEP + AI_INSTRUCTION).removeSuffix(AI_INSTRUCTION).trim().ifEmpty { null }
    }

    fun host(url: String): String? = runCatching { URI(url).host?.lowercase() }.getOrNull()

    /** what the address bar shows while you are not typing in it */
    fun display(url: String): String {
        if (url.isEmpty() || url == "about:blank") return ""
        query(url)?.let { return it }
        val h = host(url) ?: return url
        return h.removePrefix("www.")
    }

    fun editable(url: String): String = if (url == "about:blank") "" else query(url) ?: url

    /** roughly the registrable part of a host, to tell one site from another */
    fun site(host: String): String {
        val l = host.split('.')
        if (l.size <= 2) return host
        val short = setOf("co", "com", "net", "org", "gov", "edu", "ac", "or", "ne", "go")
        return if (l.last().length == 2 && l[l.size - 2] in short) l.takeLast(3).joinToString(".") else l.takeLast(2).joinToString(".")
    }

    /** sign-in, messaging and human checks: pop-ups to these are allowed */
    private val signIn = listOf("accounts.google.com", "login.microsoftonline.com", "login.live.com", "appleid.apple.com",
        "github.com", "facebook.com", "x.com", "challenges.cloudflare.com", "hcaptcha.com", "recaptcha.net", "paypal.com")

    fun isSignIn(host: String) = signIn.any { host == it || host.endsWith(".$it") }
}
