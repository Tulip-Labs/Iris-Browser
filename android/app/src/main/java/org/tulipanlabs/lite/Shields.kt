// SPDX-License-Identifier: GPL-3.0-only
package org.tulipanlabs.lite

import java.io.BufferedReader

// Iris Shields: an ad and tracker blocker that reads the usual filter lists
// (EasyList, EasyPrivacy, uBlock filters, the cookie notice list), plus the
// hiding of the boxes ads leave behind. The same design as Iris's Go engine
// (and Brave's and uBlock Origin's): every rule is filed under its rarest whole
// word, and a request only checks the rules filed under the words of its own
// address, so each request costs microseconds.

object Kind {
    const val SCRIPT = 1
    const val IMAGE = 2
    const val STYLESHEET = 4
    const val XHR = 8
    const val MEDIA = 16
    const val FONT = 32
    const val SUBDOCUMENT = 64
    const val PING = 128
    const val OTHER = 256
    const val DOCUMENT = 512
    const val ALL = 1023

    /** the kinds Iris asks about (style sheets and fonts are never blocked: pages must look right) */
    const val ASKED = SCRIPT or IMAGE or XHR or MEDIA or PING or OTHER or SUBDOCUMENT

    val names = mapOf(
        "script" to SCRIPT, "image" to IMAGE, "stylesheet" to STYLESHEET, "css" to STYLESHEET,
        "xmlhttprequest" to XHR, "xhr" to XHR, "media" to MEDIA, "font" to FONT,
        "subdocument" to SUBDOCUMENT, "frame" to SUBDOCUMENT, "ping" to PING, "beacon" to PING,
        "other" to OTHER, "object" to OTHER, "websocket" to XHR, "webrtc" to OTHER,
        "document" to DOCUMENT, "doc" to DOCUMENT, "all" to ALL,
    )
}

/** The registrable domain (example.co.uk for a.b.example.co.uk), close enough without the full suffix list. */
fun siteOf(host: String): String {
    val parts = host.split('.')
    if (parts.size <= 2) return host
    val last2 = parts[parts.size - 2] + "." + parts.last()
    val n = if (parts[parts.size - 2] in secondLevel || last2 in suffix2) 3 else 2
    return parts.takeLast(n).joinToString(".")
}

private val secondLevel = setOf("co", "com", "net", "org", "gov", "edu", "ac", "gob", "nic", "mil", "or", "ne", "go", "gv")
private val suffix2 = setOf("blogspot.com", "github.io", "gitlab.io", "pages.dev", "netlify.app", "vercel.app", "herokuapp.com",
    "appspot.com", "cloudfront.net", "azurewebsites.net", "firebaseapp.com", "web.app")

/** host of an address, lower case */
fun hostOf(url: String): String {
    var u = url.lowercase()
    val i = u.indexOf("://")
    if (i >= 0) u = u.substring(i + 3)
    for (k in u.indices) {
        val c = u[k]
        if (c == '/' || c == ':' || c == '?' || c == '#') return u.substring(0, k)
    }
    return u
}

class Shields {
    private class Rule(
        var pat: String,
        var flags: Int,
        var kinds: Int, // 0 = any
        var tokOff: Int = -1,
        val dom: MutableList<String> = ArrayList(0),
        val notDom: MutableList<String> = ArrayList(0),
        var re: Regex? = null,
    )

    private val block = HashMap<String, MutableList<Rule>>()
    private val allow = HashMap<String, MutableList<Rule>>()
    private val blockAny = ArrayList<Rule>()
    private val allowAny = ArrayList<Rule>()
    private val pageAllow = ArrayList<Rule>()
    private val siteHide = HashMap<String, MutableList<String>>()
    private val siteExcept = HashMap<String, MutableList<String>>()
    private val generic = ArrayList<String>()
    private val genericExcept = HashSet<String>()
    private val genericOff = ArrayList<Rule>()

    var rules = 0
        private set
    var hiding = 0
        private set

    @Volatile private var lastPage = ""
    @Volatile private var pageOff = false

    fun add(r: BufferedReader) {
        r.forEachLine { addLine(it) }
    }

    fun addLine(raw: String) {
        val line = raw.trim()
        if (line.isEmpty() || line[0] == '!' || line[0] == '[') return
        val ci = cosmeticSep(line)
        if (ci >= 0) {
            if (addCosmetic(line, ci)) hiding++
            return
        }
        val (r, special) = parseNetwork(line) ?: return
        val (tok, off) = bestToken(r)
        r.tokOff = if (r.pat.isEmpty()) -1 else off
        when (special) {
            "page" -> { pageAllow.add(r); return }
            "generichide" -> { genericOff.add(r); return }
        }
        rules++
        val exc = r.flags and EXCEPTION != 0
        when {
            tok.isEmpty() && exc -> allowAny.add(r)
            tok.isEmpty() -> blockAny.add(r)
            exc -> allow.getOrPut(tok) { ArrayList(1) }.add(r)
            else -> block.getOrPut(tok) { ArrayList(1) }.add(r)
        }
    }

    private fun cosmeticSep(line: String): Int {
        var i = 0
        while (i + 1 < line.length) {
            if (line[i] == '#') {
                val n = line[i + 1]
                if (n == '#' || n == '?' || n == '$' || n == '%' || (n == '@' && i + 2 < line.length && line[i + 2] == '#')) return i
            }
            i++
        }
        return -1
    }

    private fun parseNetwork(input: String): Pair<Rule, String>? {
        var line = input
        val r = Rule("", 0, 0)
        if (line.startsWith("@@")) {
            r.flags = r.flags or EXCEPTION
            line = line.substring(2)
        }
        var pat = line
        var opts = ""
        var isRegex = false
        if (pat.startsWith("/") && pat.length > 2) {
            if (pat.endsWith("/")) isRegex = true
            else {
                val j = pat.lastIndexOf("/$")
                if (j > 0 && pat.substring(j + 2).none { it == '/' || it == '\\' }) {
                    opts = pat.substring(j + 2); pat = pat.substring(0, j + 1); isRegex = true
                }
            }
        }
        if (!isRegex) {
            val j = pat.lastIndexOf('$')
            if (j >= 0 && !pat.substring(j).contains('/')) {
                opts = pat.substring(j + 1); pat = pat.substring(0, j)
            }
        }
        var special = ""
        if (opts.isNotEmpty()) {
            for (o0 in opts.split(',')) {
                val neg = o0.startsWith("~")
                val o = o0.removePrefix("~")
                val eq = o.indexOf('=')
                val name = (if (eq >= 0) o.substring(0, eq) else o).lowercase()
                val value = if (eq >= 0) o.substring(eq + 1) else ""
                when {
                    name in unsupported -> return null
                    name == "third-party" || name == "3p" -> r.flags = r.flags or (if (neg) FIRST else THIRD)
                    name == "first-party" || name == "1p" -> r.flags = r.flags or (if (neg) THIRD else FIRST)
                    name == "important" -> r.flags = r.flags or IMPORTANT
                    name == "match-case" -> r.flags = r.flags or CASE
                    name == "domain" || name == "from" -> for (d in value.split('|')) {
                        if (d.startsWith("~")) r.notDom.add(d.substring(1).lowercase()) else if (d.isNotEmpty()) r.dom.add(d.lowercase())
                    }
                    name == "redirect" || name == "empty" -> {} // blocking is what matters here
                    name == "generichide" || name == "ghide" || name == "elemhide" || name == "ehide" -> special = "generichide"
                    Kind.names.containsKey(name) -> {
                        val k = Kind.names.getValue(name)
                        if (k == Kind.DOCUMENT && !neg) { special = "page"; continue }
                        if (neg) {
                            if (r.kinds == 0) r.kinds = Kind.ALL
                            r.kinds = r.kinds and k.inv()
                        } else r.kinds = r.kinds or k
                    }
                    else -> return null // an option this engine does not know: safer to skip the rule
                }
            }
        }
        if (special.isNotEmpty() && r.flags and EXCEPTION == 0) return null
        if (special.isEmpty() && r.kinds != 0 && r.kinds and Kind.ASKED == 0) return null
        if (isRegex) {
            r.re = try { Regex(pat.substring(1, pat.length - 1)) } catch (e: Exception) { return null }
            r.flags = r.flags or REGEX
            return r to special
        }
        when {
            pat.startsWith("||") -> { r.flags = r.flags or HOST; pat = pat.substring(2) }
            pat.startsWith("|") -> { r.flags = r.flags or START; pat = pat.substring(1) }
        }
        if (pat.endsWith("|")) { r.flags = r.flags or END; pat = pat.dropLast(1) }
        pat = pat.trim('*')
        if (pat.isEmpty() && special.isEmpty()) return null
        if (r.flags and CASE == 0) pat = pat.lowercase()
        r.pat = pat
        return r to special
    }

    private fun bestToken(r: Rule): Pair<String, Int> {
        if (r.flags and REGEX != 0) return "" to -1
        val p = r.pat
        var best = ""
        var off = -1
        var star = false
        var i = 0
        while (i < p.length) {
            if (p[i] == '*') star = true
            if (!isWord(p[i])) { i++; continue }
            var j = i
            while (j < p.length && isWord(p[j])) j++
            val w = p.substring(i, j)
            val leftOK = (i > 0 && p[i - 1] != '*') || (i == 0 && r.flags and (HOST or START) != 0)
            val rightOK = (j < p.length && p[j] != '*') || (j == p.length && r.flags and END != 0)
            if (leftOK && rightOK && w.length >= 2 && w !in common && w.length > best.length) {
                best = w.lowercase()
                off = if (star) -1 else i
            }
            i = j
        }
        return best to off
    }

    private class Req(val url: String, val kind: Int, page: String) {
        val lower = url.lowercase()
        val hostStart: Int
        val hostEnd: Int
        val host: String
        val page: String = hostOf(page)
        val third: Boolean

        init {
            val i = lower.indexOf("://")
            hostStart = if (i >= 0) i + 3 else 0
            var e = lower.length
            for (k in hostStart until lower.length) {
                val c = lower[k]
                if (c == '/' || c == ':' || c == '?' || c == '#') { e = k; break }
            }
            hostEnd = e
            host = lower.substring(hostStart, hostEnd)
            third = this.page.isNotEmpty() && siteOf(host) != siteOf(this.page)
        }
    }

    /** Whether a request should not load. Safe from any thread. */
    fun blocked(url: String, page: String, kind: Int): Boolean {
        if (shieldOffOn(page)) return false
        val r = Req(url, kind, page)
        val hit = find(block, blockAny, r) ?: return false
        if (hit.flags and IMPORTANT != 0) return true
        return find(allow, allowAny, r) == null
    }

    /** Whether an exception rule lets a request through (lifts the built-in list too). */
    fun excepted(url: String, page: String, kind: Int): Boolean = find(allow, allowAny, Req(url, kind, page)) != null

    private fun shieldOffOn(page: String): Boolean {
        if (page != lastPage) {
            var off = false
            if (page.isNotEmpty()) {
                val r = Req(page, Kind.DOCUMENT, page)
                off = pageAllow.any { matches(it, r, true) }
            }
            pageOff = off
            lastPage = page
        }
        return pageOff
    }

    private fun find(idx: Map<String, List<Rule>>, any: List<Rule>, r: Req): Rule? {
        val s = r.lower
        var i = 0
        while (i < s.length) {
            if (!isWord(s[i])) { i++; continue }
            var j = i
            while (j < s.length && isWord(s[j])) j++
            idx[s.substring(i, j)]?.let { list -> for (rl in list) if (matches(rl, r, false)) return rl }
            i = j
        }
        for (rl in any) if (matches(rl, r, false)) return rl
        return null
    }

    private fun matches(rl: Rule, r: Req, pageRule: Boolean): Boolean {
        if (!pageRule) {
            if (rl.kinds != 0 && rl.kinds and r.kind == 0) return false
            if ((rl.flags and THIRD != 0 && !r.third) || (rl.flags and FIRST != 0 && r.third)) return false
        }
        if ((rl.dom.isNotEmpty() || rl.notDom.isNotEmpty()) && !domainOK(r.page, rl.dom, rl.notDom)) return false
        val s = if (rl.flags and CASE != 0) r.url else r.lower
        rl.re?.let { return it.containsMatchIn(s) }
        val end = rl.flags and END != 0
        fun tryAt(start: Int): Boolean {
            if (start < 0 || start > s.length) return false
            if (rl.flags and START != 0 && start != 0) return false
            if (rl.flags and HOST != 0 && !(start >= r.hostStart && start < r.hostEnd && (start == r.hostStart || s[start - 1] == '.'))) return false
            return glob(rl.pat, s, start, end)
        }
        when {
            rl.flags and START != 0 -> return tryAt(0)
            rl.flags and HOST != 0 -> {
                for (k in r.hostStart until r.hostEnd) if ((k == r.hostStart || s[k - 1] == '.') && tryAt(k)) return true
                return false
            }
            rl.tokOff >= 0 && rl.tokOff < rl.pat.length -> {
                var n = rl.tokOff
                while (n < rl.pat.length && isWord(rl.pat[n])) n++
                val tok = rl.pat.substring(rl.tokOff, n)
                var from = 0
                while (true) {
                    val k = s.indexOf(tok, from)
                    if (k < 0) return false
                    if (tryAt(k - rl.tokOff)) return true
                    from = k + 1
                }
            }
        }
        for (k in 0..s.length) if (tryAt(k)) return true
        return false
    }

    // ---- hiding rules ----

    private fun addCosmetic(line: String, i: Int): Boolean {
        val domains = line.substring(0, i)
        var rest = line.substring(i)
        val exc: Boolean
        when {
            rest.startsWith("##") -> { rest = rest.substring(2); exc = false }
            rest.startsWith("#@#") -> { rest = rest.substring(3); exc = true }
            else -> return false // procedural, CSS injection or scripts
        }
        val sel = rest.trim()
        if (sel.isEmpty() || sel.startsWith("+js") || sel.startsWith("^") || sel.contains('{') || sel.contains('}')) return false
        if (procedural.any { sel.contains(it) }) return false
        if (domains.isEmpty()) {
            if (exc) genericExcept.add(sel)
            else if (generic.size < 4000) generic.add(sel) else return false
            return true
        }
        for (d0 in domains.split(',')) {
            val d = d0.trim().lowercase()
            if (d.isEmpty() || d.startsWith("~")) continue
            (if (exc) siteExcept else siteHide).getOrPut(d) { ArrayList(2) }.add(sel)
        }
        return true
    }

    /** the names a page's hiding rules can be filed under (its host, parent domains, name.*) */
    private fun siteKeys(host: String): List<String> {
        val out = ArrayList<String>()
        var h = host
        while (h.isNotEmpty()) {
            out.add(h)
            val i = h.indexOf('.')
            if (i < 0) break
            h = h.substring(i + 1)
        }
        val site = siteOf(host)
        val name = site.substringBefore('.')
        h = host.removeSuffix(site) + name
        while (h.isNotEmpty()) {
            out.add("$h.*")
            val i = h.indexOf('.')
            if (i < 0) break
            h = h.substring(i + 1)
        }
        return out
    }

    /** The style sheet that hides ads on a page: its site's rules and the generic ones. */
    fun hidingCSS(page: String): String {
        if (page.isEmpty() || shieldOffOn(page)) return ""
        val host = hostOf(page)
        val keys = siteKeys(host)
        val ex = HashSet<String>()
        for (k in keys) siteExcept[k]?.let { ex.addAll(it) }
        val out = LinkedHashSet<String>()
        for (k in keys) siteHide[k]?.forEach { if (it !in ex) out.add(it) }
        val r = Req(page, Kind.DOCUMENT, page)
        if (genericOff.none { matches(it, r, true) }) {
            for (s in generic) if (s !in genericExcept && s !in ex) out.add(s)
        }
        if (out.isEmpty()) return ""
        // in groups, so one selector the engine cannot read does not void the rest
        return out.chunked(400).joinToString("\n") { it.joinToString(",") + "{display:none!important}" }
    }

    companion object {
        private const val HOST = 1
        private const val START = 2
        private const val END = 4
        private const val EXCEPTION = 8
        private const val IMPORTANT = 16
        private const val THIRD = 32
        private const val FIRST = 64
        private const val CASE = 128
        private const val REGEX = 256

        private val unsupported = setOf(
            "csp", "removeparam", "redirect-rule", "replace", "rewrite", "popup", "popunder", "header", "permissions",
            "urlskip", "uritransform", "urltransform", "jsonprune", "denyallow", "to", "badfilter", "cname", "inline-script",
            "inline-font", "mp4", "genericblock", "specifichide", "shide", "method", "ipaddress", "strict1p", "strict3p",
            "strict-first-party", "strict-third-party", "responseheader", "trusted-urlskip",
        )
        private val common = setOf("http", "https", "www", "com", "js", "net", "org", "html", "php")
        private val procedural = listOf(":has-text(", ":upward(", ":xpath(", ":matches-css", ":-abp-", ":style(", ":remove(",
            ":min-text-length(", ":watch-attr(", ":matches-path(", ":matches-attr(", ":matches-prop(", ":others(", ":shadow(", "+js(", ":contains(")

        private fun isWord(c: Char) = c in 'a'..'z' || c in '0'..'9' || c in 'A'..'Z' || c == '%'

        private fun isSep(c: Char) = !(c in 'a'..'z' || c in 'A'..'Z' || c in '0'..'9' || c == '_' || c == '-' || c == '.' || c == '%')

        /** pattern p (with * and the ^ separator) against s from `from`: its start, or all of it when end is set */
        private fun glob(p: String, s: String, from: Int, end: Boolean): Boolean {
            var pi = 0
            var si = from
            var star = -1
            var mark = 0
            while (true) {
                if (pi == p.length) {
                    if (!end || si == s.length) return true
                } else {
                    val c = p[pi]
                    if (c == '*') { star = pi; mark = si; pi++; continue }
                    if (si < s.length && (c == s[si] || (c == '^' && isSep(s[si])))) { pi++; si++; continue }
                    if (c == '^' && si == s.length) { pi++; continue }
                }
                if (star < 0) return false
                mark++
                if (mark > s.length) return false
                pi = star + 1
                si = mark
            }
        }

        private fun hostIs(host: String, d: String): Boolean {
            if (d.endsWith(".*")) {
                val site = siteOf(host)
                val h = host.removeSuffix(site) + site.substringBefore('.')
                val base = d.dropLast(2)
                return h == base || h.endsWith(".$base")
            }
            return host == d || host.endsWith(".$d")
        }

        private fun domainOK(page: String, dom: List<String>, notDom: List<String>): Boolean {
            if (notDom.any { hostIs(page, it) }) return false
            return dom.isEmpty() || dom.any { hostIs(page, it) }
        }
    }
}

/** A short built-in list of the commonest ad and tracker hosts: the shield works before the lists arrive. */
object BuiltIn {
    private val hosts = setOf(
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "google-analytics.com", "googletagmanager.com",
        "googletagservices.com", "adservice.google.com", "pagead2.googlesyndication.com", "imasdk.googleapis.com",
        "amazon-adsystem.com", "adnxs.com", "adsrvr.org", "pubmatic.com", "rubiconproject.com", "casalemedia.com",
        "openx.net", "criteo.com", "criteo.net", "taboola.com", "outbrain.com", "scorecardresearch.com", "quantserve.com",
        "moatads.com", "hotjar.com", "mixpanel.com", "segment.io", "connect.facebook.net", "analytics.tiktok.com",
        "ads.yahoo.com", "advertising.com", "bidswitch.net", "smartadserver.com", "teads.tv", "yieldmo.com",
        "media.net", "zedo.com", "adform.net", "33across.com", "sharethrough.com", "indexww.com", "lijit.com",
        "adsafeprotected.com", "doubleverify.com", "chartbeat.com", "newrelic.com", "nr-data.net", "clarity.ms",
        "bat.bing.com", "ads.linkedin.com", "px.ads.linkedin.com", "static.ads-twitter.com", "ads-api.twitter.com",
    )

    fun blocked(host: String): Boolean {
        var h = host
        while (true) {
            if (h in hosts) return true
            val i = h.indexOf('.')
            if (i < 0) return false
            h = h.substring(i + 1)
        }
    }
}
