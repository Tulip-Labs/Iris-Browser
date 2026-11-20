// SPDX-License-Identifier: GPL-3.0-only
package org.tulipanlabs.lite

import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

// What the address bar opens, and the filter lists. Every search asks Google
// AI Mode, as on the desktop (core/search.go), with the same instruction
// after the reader's words; "yt " before words searches YouTube.

enum class Mode { AI, YOUTUBE }

object Search {
    /** goes with every search sent to AI Mode (the desktop's AIInstruction) */
    const val AI_INSTRUCTION = "Use only high-quality, authoritative and up-to-date sources (official sites, documentation, peer-reviewed research, reputable news) and cite them. Answer clearly, precisely and concisely, with the most recent information."
    private const val AI_SEP = "\n\n"

    // file types people type that are not web addresses ("node.js", "main.py")
    private val notTLD = setOf("js", "ts", "jsx", "tsx", "py", "kt", "java", "cpp", "rs", "json", "txt", "exe", "yml", "yaml", "toml", "css", "html", "pdf", "docx", "xlsx")
    private val ipv4 = Regex("\\d{1,3}(\\.\\d{1,3}){3}")
    private val hostLike = Regex("^[\\p{L}0-9-]+(\\.[\\p{L}0-9-]+)+(:\\d+)?(/.*)?$")

    fun enc(s: String): String = URLEncoder.encode(s, "UTF-8")

    /** The address for what was typed: an address as is (https first), or a search. */
    fun resolve(text: String): String {
        val t = text.trim()
        if (t.isEmpty()) return ""
        val lower = t.lowercase()
        if (lower.startsWith("http://") || lower.startsWith("https://") || lower.startsWith("about:") || lower.startsWith("data:")) return t
        if (!t.contains(' ')) {
            val hostPart = t.substringBefore('/').substringBefore(':')
            if (lower.startsWith("localhost") || ipv4.matches(hostPart)) return "http://$t"
            if (hostLike.matches(t)) {
                val tld = hostPart.substringAfterLast('.')
                if (tld.length >= 2 && tld.all { it.isLetter() } && tld.lowercase() !in notTLD) return "https://$t"
            }
        }
        if (lower.startsWith("yt ")) return url(t.substring(3), Mode.YOUTUBE)
        return url(t, Mode.AI)
    }

    fun url(q: String, mode: Mode): String {
        val e = enc(q.trim())
        return when (mode) {
            Mode.AI -> "https://www.google.com/search?q=" + enc(q.trim() + AI_SEP + AI_INSTRUCTION) + "&udm=50"
            Mode.YOUTUBE -> "https://m.youtube.com/results?search_query=$e"
        }
    }

    /** The words of a search, to show in the address bar instead of the long address. */
    fun query(url: String): String? {
        val host = hostOf(url)
        val key = when {
            (host.startsWith("www.google.") || host.startsWith("google.")) && url.contains("/search?") -> "q"
            host.endsWith("youtube.com") && url.contains("/results?") -> "search_query"
            else -> return null
        }
        val q = url.substringAfter('?').split('&').firstOrNull { it.startsWith("$key=") } ?: return null
        val words = try { java.net.URLDecoder.decode(q.substringAfter('='), "UTF-8") } catch (e: Exception) { return null }
        // the reader's own words, without the instruction Iris added
        return words.substringBefore(AI_SEP + AI_INSTRUCTION).removeSuffix(AI_INSTRUCTION).trim().ifEmpty { null }
    }

    /** Google's suggestions for what is being typed (on a background thread). */
    fun suggest(text: String): List<String> = try {
        val c = URL("https://suggestqueries.google.com/complete/search?client=firefox&q=" + enc(text)).openConnection() as HttpURLConnection
        c.connectTimeout = 2500
        c.readTimeout = 2500
        val body = c.inputStream.bufferedReader().use { it.readText() }
        c.disconnect()
        // ["text",["one","two",...]]
        val list = body.substringAfter(",[", "").substringBefore("]")
        Regex("\"((?:[^\"\\\\]|\\\\.)*)\"").findAll(list).map { unescape(it.groupValues[1]) }.take(6).toList()
    } catch (e: Exception) {
        emptyList()
    }

    private fun unescape(s: String): String {
        if (!s.contains('\\')) return s
        val b = StringBuilder()
        var i = 0
        while (i < s.length) {
            val c = s[i]
            if (c == '\\' && i + 1 < s.length) {
                val n = s[i + 1]
                if (n == 'u' && i + 5 < s.length) {
                    b.append(s.substring(i + 2, i + 6).toIntOrNull(16)?.toChar() ?: '?'); i += 6; continue
                }
                b.append(n); i += 2; continue
            }
            b.append(c); i++
        }
        return b.toString()
    }
}

/** The filter lists Iris Shields uses, kept up to date in the background. */
object FilterLists {
    class List(val id: String, val name: String, val urls: kotlin.collections.List<String>)

    val all = listOf(
        List("easylist", "EasyList (ads)", listOf("https://easylist.to/easylist/easylist.txt", "https://ublockorigin.github.io/uAssets/thirdparties/easylist.txt")),
        List("easyprivacy", "EasyPrivacy (trackers)", listOf("https://easylist.to/easylist/easyprivacy.txt", "https://ublockorigin.github.io/uAssets/thirdparties/easyprivacy.txt")),
        List("ublock", "uBlock filters", listOf("https://ublockorigin.github.io/uAssets/filters/filters.txt", "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/filters.txt")),
        List("cookies", "EasyList Cookie (cookie notices)", listOf("https://secure.fanboy.co.nz/fanboy-cookiemonster.txt", "https://ublockorigin.github.io/uAssets/thirdparties/easylist-cookies.txt")),
    )

    const val MAX_AGE_MS = 4L * 24 * 3600 * 1000

    private fun fetch(urls: kotlin.collections.List<String>): ByteArray? {
        for (u in urls) {
            try {
                val c = URL(u).openConnection() as HttpURLConnection
                c.connectTimeout = 15000
                c.readTimeout = 40000
                c.setRequestProperty("User-Agent", "Iris/1.0 (filter lists)")
                if (c.responseCode != 200) { c.disconnect(); continue }
                val b = c.inputStream.use { it.readBytes() }
                c.disconnect()
                if (String(b, 0, minOf(b.size, 4096)).contains('!')) return b
            } catch (e: Exception) {
            }
        }
        return null
    }

    /**
     * Builds the engine from the lists in dir, fetching those that are missing
     * or old when refresh is set. Runs on a background thread.
     */
    fun load(dir: File, wanted: Set<String>, refresh: Boolean): Shields {
        dir.mkdirs()
        val e = Shields()
        for (l in all) {
            if (l.id !in wanted) continue
            val f = File(dir, l.id + ".txt")
            val old = !f.exists() || System.currentTimeMillis() - f.lastModified() > MAX_AGE_MS
            if (refresh && old) {
                fetch(l.urls)?.let { b ->
                    val tmp = File(dir, l.id + ".tmp")
                    tmp.writeBytes(b)
                    tmp.renameTo(f)
                }
            }
            if (f.exists()) f.bufferedReader().use { e.add(it) }
        }
        return e
    }

    fun updatedAt(dir: File): Long = all.maxOfOrNull { File(dir, it.id + ".txt").lastModified() } ?: 0L
}
