package org.tulipanlabs.iris

import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.zip.GZIPInputStream
import kotlin.concurrent.thread

/**
 * Iris Shields on the phone: the level's lists are fetched (and fetched
 * again every four days), read into the filter engine in the background,
 * and every request Chromium is about to make asks it first.
 */
object Shields {
    @Volatile var core: ShieldCore = ShieldCore(ShieldLevel.AGGRESSIVE, null, emptySet())
        private set
    @Volatile private var domains: Set<String> = emptySet()
    private lateinit var dir: File
    @Volatile private var loading = false
    /** called on the main thread when new rules are in place */
    var changed: (() -> Unit)? = null

    val ready get() = core.level == Store.shieldLevel && (domains.isNotEmpty())

    fun init(filesDir: File, domainList: () -> String?) {
        dir = File(filesDir, "lists").apply { mkdirs() }
        ShieldCore.guard = { page -> onFor(page) }
        thread(name = "shields") {
            runCatching {
                val text = domainList() ?: return@runCatching
                val a = org.json.JSONArray(text)
                val s = HashSet<String>(a.length() * 2)
                for (i in 0 until a.length()) a.getString(i).let { if (ShieldCore.usable(it)) s.add(it) }
                domains = s
            }
            build(Store.shieldLevel)
            refresh()
        }
    }

    /** whether Shields guard this page's site */
    fun onFor(page: String): Boolean {
        if (!Store.shields) return false
        val h = hostOf(page)
        if (ShieldCore.isYouTube(h)) return false
        if (h.isEmpty()) return true
        return Search.site(h) !in Store.shieldsOff
    }

    fun isBlocked(host: String): Boolean {
        var h = host
        while (true) {
            if (h in domains) return true
            val i = h.indexOf('.')
            if (i < 0) return false
            h = h.substring(i + 1)
            if (!h.contains('.')) return false
        }
    }

    fun levelChanged() = thread(name = "shields") { build(Store.shieldLevel) }

    private fun file(l: ShieldList) = File(dir, l.id + ".txt")

    /** reads the level's lists (fetching the missing ones first) */
    @Synchronized private fun build(level: ShieldLevel) {
        level.lists.filter { !file(it).exists() }.forEach(::fetch)
        val f = Filters()
        var any = false
        for (l in level.lists) {
            val file = file(l)
            if (!file.exists()) continue
            runCatching { file.bufferedReader().use { f.add(it) }; any = true }
        }
        if (level != Store.shieldLevel) return
        core = ShieldCore(level, if (any) f else null, domains)
        android.os.Handler(android.os.Looper.getMainLooper()).post { changed?.invoke() }
    }

    /** lists older than four days are fetched again, and the rules made again */
    private fun refresh() {
        val old = Store.shieldLevel.lists.filter { System.currentTimeMillis() - file(it).lastModified() > 4 * 86_400_000L }
        if (old.isEmpty()) return
        old.forEach(::fetch)
        build(Store.shieldLevel)
    }

    /** a list, written whole or not at all */
    private fun fetch(l: ShieldList) {
        for (u in l.urls) {
            val ok = runCatching {
                val c = URL(u).openConnection() as HttpURLConnection
                c.connectTimeout = 15_000
                c.readTimeout = 30_000
                c.setRequestProperty("User-Agent", "Iris/${BuildConfig.VERSION_NAME}")
                try {
                    if (c.responseCode != 200) return@runCatching false
                    val bytes = c.inputStream.use { it.readBytes() }
                    val head = String(bytes, 0, minOf(bytes.size, 32))
                    if (bytes.size < 1000 || !(head.startsWith("!") || head.startsWith("["))) return@runCatching false
                    val tmp = File(dir, l.id + ".new")
                    tmp.writeBytes(bytes)
                    tmp.renameTo(file(l))
                } finally {
                    c.disconnect()
                }
            }.getOrDefault(false)
            if (ok) return
        }
    }

    fun gunzipAsset(open: () -> java.io.InputStream): String? =
        runCatching { GZIPInputStream(open()).bufferedReader().use { it.readText() } }.getOrNull()
}
