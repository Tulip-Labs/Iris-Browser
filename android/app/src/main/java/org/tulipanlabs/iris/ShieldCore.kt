package org.tulipanlabs.iris

/** How hard Iris Shields block, as in Brave (the same three as on Linux). */
enum class ShieldLevel(val title: String, val hint: String, val about: String) {
    MODERATE("Moderate", "Other sites' ads",
        "Ads and trackers from other sites (EasyList, EasyPrivacy). A site's own requests always load."),
    AGGRESSIVE("Aggressive", "All ads, trackers",
        "Also a site's own ads and trackers, uBlock Origin's filters, and the empty boxes ads leave."),
    ULTRA("Ultra aggressive", "Also pop-ups, cookies",
        "Also cookie notices, newsletter and sign-up pop-ups and other annoyances. uBlock's fixes for broken sites stay on.");

    /** the lists this level reads; uBlock's fixes for broken sites at every level */
    val lists: List<ShieldList> get() {
        val base = listOf(ShieldList.EASYLIST, ShieldList.EASYPRIVACY, ShieldList.UNBREAK)
        return when (this) {
            MODERATE -> base
            AGGRESSIVE -> base + listOf(ShieldList.UBLOCK, ShieldList.UBLOCK_PRIVACY, ShieldList.QUICK_FIXES)
            ULTRA -> base + listOf(ShieldList.UBLOCK, ShieldList.UBLOCK_PRIVACY, ShieldList.QUICK_FIXES, ShieldList.COOKIES, ShieldList.ANNOYANCES)
        }
    }

    companion object {
        fun of(name: String?) = entries.firstOrNull { it.name.equals(name, true) } ?: AGGRESSIVE
    }
}

/** a filter list, from uBlock Origin's mirrors */
enum class ShieldList(val id: String, path: String) {
    EASYLIST("easylist", "thirdparties/easylist.txt"),
    EASYPRIVACY("easyprivacy", "thirdparties/easyprivacy.txt"),
    UNBREAK("unbreak", "filters/unbreak.txt"),
    UBLOCK("ublock", "filters/filters.txt"),
    UBLOCK_PRIVACY("ublock-privacy", "filters/privacy.txt"),
    QUICK_FIXES("quick-fixes", "filters/quick-fixes.txt"),
    COOKIES("cookies", "thirdparties/easylist-cookies.txt"),
    ANNOYANCES("annoyances", "filters/annoyances-others.txt");

    val urls = listOf(
        "https://ublockorigin.github.io/uAssets/$path",
        "https://raw.githubusercontent.com/uBlockOrigin/uAssets/gh-pages/$path",
        "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/$path",
    )
}

/**
 * The decisions of Iris Shields, without Android: which requests Chromium
 * never sends, and what the page's style sheet hides. Built from a level's
 * lists, plus Iris's own list of about 100,000 ad and tracker domains for
 * other sites' requests.
 */
class ShieldCore(val level: ShieldLevel, private val filters: Filters?, private val domains: Set<String>) {
    /** whether a request of `page` to `url` (of kind, see Kind) is stopped */
    fun blocks(url: String, page: String, kind: Int, mainFrame: Boolean): Boolean {
        if (mainFrame || !url.startsWith("http")) return false
        if (!onFor(page)) return false
        if (kind == Kind.STYLESHEET || kind == Kind.FONT) return false // pages must look right
        val host = hostOf(url)
        if (never(host)) return false
        val third = siteOf(host) != siteOf(hostOf(page))
        // Moderate: a site's own requests always go
        if (level == ShieldLevel.MODERATE && !third) return false
        val f = filters
        if (f != null && f.blocked(url, page, kind)) return true
        return third && listed(host) && (f == null || !f.excepted(url, page, kind))
    }

    /** the style sheet hiding what ads leave: Moderate hides only what the
     *  lists name for this site, the others everything they name */
    fun hidingCSS(page: String): String {
        if (!onFor(page) || !page.startsWith("http")) return ""
        return filters?.hidingCSS(page, generic = level != ShieldLevel.MODERATE) ?: ""
    }

    private fun listed(host: String): Boolean {
        var h = host
        while (true) {
            if (h in domains) return true
            val i = h.indexOf('.')
            if (i < 0) return false
            h = h.substring(i + 1)
            if (!h.contains('.')) return false
        }
    }

    companion object {
        /** messaging, sign-in and human checks: never blocked */
        val neverList = listOf("whatsapp.com", "whatsapp.net", "accounts.google.com", "login.microsoftonline.com",
            "login.live.com", "teams.microsoft.com", "meet.google.com", "challenges.cloudflare.com", "hcaptcha.com",
            "recaptcha.net", "appleid.apple.com")

        /** delivery networks that carry ordinary sites: a list entry naming one whole is dropped */
        val shared = setOf("cloudfront.net", "amazonaws.com", "akamaihd.net", "akamaized.net", "akamai.net",
            "fastly.net", "azureedge.net", "googleusercontent.com", "googleapis.com", "gstatic.com", "cloudflare.com",
            "jsdelivr.net", "unpkg.com", "github.io", "githubusercontent.com", "netlify.app", "vercel.app", "wp.com",
            "cloudinary.com", "imgix.net", "ctfassets.net", "shopifycdn.com", "myshopify.com", "wixstatic.com")

        fun never(host: String) = neverList.any { host == it || host.endsWith(".$it") }

        fun usable(d: String) = d.contains('.') && d !in shared && neverList.none { d == it || d.endsWith(".$it") || it.endsWith(".$d") }

        /** YouTube sees no ad blocker (it fights them): its ads are skipped instead */
        fun isYouTube(h: String) = h == "youtube.com" || h.endsWith(".youtube.com") || h == "youtube-nocookie.com" || h.endsWith(".youtube-nocookie.com")

        /** set by the app: whether Shields guard this page (on, not off for its site, not YouTube) */
        @Volatile var guard: (String) -> Boolean = { page -> !isYouTube(hostOf(page)) }
    }

    private fun onFor(page: String) = guard(page)
}

