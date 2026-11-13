// SPDX-License-Identifier: GPL-3.0-only
package org.tulipanlabs.lite

import java.net.URI
import java.net.URLDecoder

// Links without tracking: the tags that follow you from site to site are
// removed, tracking redirects are skipped, and AMP copies open the original.

object Links {
    private val tracking = setOf(
        "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "utm_id", "utm_name", "utm_reader",
        "utm_social", "utm_social-type", "fbclid", "gclid", "dclid", "gbraid", "wbraid", "gclsrc", "msclkid", "mc_cid",
        "mc_eid", "yclid", "igshid", "igsh", "_hsenc", "_hsmi", "__hssc", "__hstc", "__hsfp", "hsctatracking",
        "oly_anon_id", "oly_enc_id", "vero_id", "vero_conv", "rb_clickid", "s_cid", "ml_subscriber", "ml_subscriber_hash",
        "twclid", "ttclid", "srsltid", "mkt_tok", "epik", "_branch_match_id", "_kx", "ref_src", "ref_url", "wickedid",
        "guccounter", "guce_referrer", "guce_referrer_sig", "sc_cid", "ncid", "cmpid",
    )

    private val siteParams = mapOf(
        "youtube.com" to listOf("si", "pp", "feature"), "youtu.be" to listOf("si", "feature"), "music.youtube.com" to listOf("si"),
        "open.spotify.com" to listOf("si", "context"), "x.com" to listOf("s", "t"), "twitter.com" to listOf("s", "t"),
        "instagram.com" to listOf("igsh", "img_index"),
        "amazon.com" to listOf("ref_", "pd_rd_r", "pd_rd_w", "pd_rd_wg", "pf_rd_p", "pf_rd_r", "content-id"),
    )

    private data class Redirector(val host: String, val path: String, val param: String)

    private val redirectors = listOf(
        Redirector("google.", "/url", "q"), Redirector("google.", "/url", "url"), Redirector("l.facebook.com", "/l.php", "u"),
        Redirector("lm.facebook.com", "/l.php", "u"), Redirector("l.instagram.com", "/", "u"), Redirector("out.reddit.com", "", "url"),
        Redirector("www.youtube.com", "/redirect", "q"), Redirector("steamcommunity.com", "/linkfilter/", "url"),
        Redirector("go.redirectingat.com", "", "url"), Redirector("click.linksynergy.com", "", "murl"),
        Redirector("www.awin1.com", "/cread.php", "ued"), Redirector("t.umblr.com", "/redirect", "z"), Redirector("exit.sc", "/", "url"),
        Redirector("slack-redir.net", "/link", "url"), Redirector("vk.com", "/away.php", "to"), Redirector("away.vk.com", "/away.php", "to"),
        Redirector("duckduckgo.com", "/l/", "uddg"),
    )

    /** The address without tracking (the same string when there is none). */
    fun clean(input: String): String {
        var raw = input
        repeat(3) { // redirects can be nested
            val next = unwrap(raw)
            if (next == raw) return@repeat
            raw = next
        }
        val u = try { URI(raw) } catch (e: Exception) { return raw }
        val q = u.rawQuery ?: return raw
        if (u.scheme != "http" && u.scheme != "https") return raw
        val host = (u.host ?: return raw).lowercase().removePrefix("www.")
        val extra = HashSet<String>()
        for ((h, ps) in siteParams) if (host == h || host.endsWith(".$h")) extra.addAll(ps)
        var changed = false
        val keep = q.split('&').filter { p ->
            val n = decode(p.substringBefore('=')).lowercase()
            val drop = n in tracking || n in extra || n.startsWith("utm_") || n.startsWith("pf_rd_") || n.startsWith("pd_rd_")
            if (drop) changed = true
            !drop
        }
        if (!changed) return raw
        // rebuild around the query so the rest keeps its exact encoding
        val i = raw.indexOf('?')
        val hash = raw.indexOf('#', i).let { if (it < 0) "" else raw.substring(it) }
        val base = raw.substring(0, i)
        return if (keep.isEmpty()) base + hash else base + "?" + keep.joinToString("&") + hash
    }

    private fun decode(s: String): String = try { URLDecoder.decode(s, "UTF-8") } catch (e: Exception) { s }

    private fun param(query: String?, name: String): String? {
        if (query == null) return null
        for (p in query.split('&')) {
            val k = p.substringBefore('=')
            if (k == name) return decode(p.substringAfter('=', ""))
        }
        return null
    }

    private fun unwrap(raw: String): String {
        val u = try { URI(raw) } catch (e: Exception) { return raw }
        val host = (u.host ?: return raw).lowercase()
        val path = u.rawPath ?: ""
        val query = if (u.rawQuery != null) "?" + u.rawQuery else ""
        if (host.contains("google.") && path.startsWith("/amp/s/")) return "https://" + path.removePrefix("/amp/s/") + query
        if (host.endsWith(".cdn.ampproject.org")) {
            for (pre in listOf("/c/s/", "/v/s/", "/i/s/")) if (path.startsWith(pre)) return "https://" + path.removePrefix(pre) + query
        }
        for (r in redirectors) {
            val isGoogle = r.host.startsWith("google.") && host.contains("google.") && (host.startsWith("google.") || host.startsWith("www.google."))
            if (host != r.host && !isGoogle) continue
            if (r.path.isNotEmpty() && !path.startsWith(r.path)) continue
            val t = param(u.rawQuery, r.param) ?: continue
            if (t.startsWith("http://") || t.startsWith("https://")) return t
        }
        return raw
    }
}
