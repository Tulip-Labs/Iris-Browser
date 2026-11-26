package org.tulipanlabs.iris

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** a container: a world of its own (cookies, storage, cache, sign-ins) */
data class Container(val id: String, val name: String, val color: Long, val icon: String = "star") {
    companion object {
        const val PRIVATE = "private"
        val palette = listOf(0xFF0A84FF, 0xFFFF9F0A, 0xFF30D158, 0xFFFF375F, 0xFFBF5AF2, 0xFF64D2FF, 0xFFFFD60A, 0xFFAC8E68)
        /** the icons a container can wear (the same twelve as on Linux) */
        val icons = listOf("person", "briefcase", "cart", "bank", "home", "heart", "game", "book", "plane", "code", "music", "star")
    }
}

data class SavedTab(val url: String, val title: String, val container: String?)

data class Visit(val url: String, val title: String, val visits: Int, val last: Long)

/** Iris's small store: settings, containers, the open tabs, history. */
object Store {
    private lateinit var p: SharedPreferences

    fun init(c: Context) {
        p = c.getSharedPreferences("iris", Context.MODE_PRIVATE)
        if (!p.contains("containers")) {
            containers = listOf("Personal" to "person", "Work" to "briefcase", "Shopping" to "cart", "Banking" to "bank").mapIndexed { i, (n, icon) ->
                Container(UUID.randomUUID().toString(), n, Container.palette[i], icon)
            }
        }
    }

    var shields: Boolean
        get() = p.getBoolean("shields", true)
        set(v) = p.edit().putBoolean("shields", v).apply()

    /** audio keeps playing when the screen goes off or Iris leaves the
     *  screen: the page is not paused, and a foreground service keeps it
     *  alive with the controls in the notification */
    var backgroundAudio: Boolean
        get() = p.getBoolean("backgroundAudio", true)
        set(v) = p.edit().putBoolean("backgroundAudio", v).apply()

    /** the notification permission was asked once, the first time audio
     *  played (never at launch, and never again after an answer) */
    var askedNotifications: Boolean
        get() = p.getBoolean("askedNotifications", false)
        set(v) = p.edit().putBoolean("askedNotifications", v).apply()

    /** how hard Shields block: Moderate, Aggressive or Ultra aggressive */
    var shieldLevel: ShieldLevel
        get() = ShieldLevel.of(p.getString("shieldLevel", null))
        set(v) = p.edit().putString("shieldLevel", v.name).apply()

    /** Light, Dark or Auto (the phone's choice) */
    var appearance: String
        get() = p.getString("appearance", "auto") ?: "auto"
        set(v) = p.edit().putString("appearance", v).apply()

    /** sites with Shields off */
    var shieldsOff: Set<String>
        get() = p.getStringSet("shieldsOff", emptySet()) ?: emptySet()
        set(v) = p.edit().putStringSet("shieldsOff", v).apply()

    var lastUpdateCheck: Long
        get() = p.getLong("lastUpdateCheck", 0)
        set(v) = p.edit().putLong("lastUpdateCheck", v).apply()

    var containers: List<Container>
        get() = runCatching {
            val a = JSONArray(p.getString("containers", "[]"))
            (0 until a.length()).map { a.getJSONObject(it).let { o -> Container(o.getString("id"), o.getString("name"), o.getLong("color"), o.optString("icon", "star")) } }
        }.getOrDefault(emptyList())
        set(v) {
            val a = JSONArray()
            v.forEach { a.put(JSONObject().put("id", it.id).put("name", it.name).put("color", it.color).put("icon", it.icon)) }
            p.edit().putString("containers", a.toString()).apply()
        }

    fun container(id: String?): Container? = when (id) {
        null -> null
        Container.PRIVATE -> Container(Container.PRIVATE, "Private", 0xFF5E5CE6, "private")
        else -> containers.firstOrNull { it.id == id }
    }

    var tabs: List<SavedTab>
        get() = runCatching {
            val a = JSONArray(p.getString("tabs", "[]"))
            (0 until a.length()).map {
                val o = a.getJSONObject(it)
                SavedTab(o.getString("url"), o.optString("title"), if (o.has("container")) o.getString("container") else null)
            }
        }.getOrDefault(emptyList())
        set(v) {
            val a = JSONArray()
            v.forEach { t -> a.put(JSONObject().put("url", t.url).put("title", t.title).apply { t.container?.let { put("container", it) } }) }
            p.edit().putString("tabs", a.toString()).apply()
        }

    var selected: Int
        get() = p.getInt("selected", 0)
        set(v) = p.edit().putInt("selected", v).apply()

    // history: the pages you went to, for the new-tab page

    private var historyCache: MutableList<Visit>? = null

    private fun history(): MutableList<Visit> {
        historyCache?.let { return it }
        val list = runCatching {
            val a = JSONArray(p.getString("history", "[]"))
            (0 until a.length()).map {
                val o = a.getJSONObject(it)
                Visit(o.getString("url"), o.optString("title"), o.optInt("visits", 1), o.optLong("last"))
            }.toMutableList()
        }.getOrDefault(mutableListOf())
        historyCache = list
        return list
    }

    private fun saveHistory() {
        val a = JSONArray()
        history().forEach { a.put(JSONObject().put("url", it.url).put("title", it.title).put("visits", it.visits).put("last", it.last)) }
        p.edit().putString("history", a.toString()).apply()
    }

    /**
     * A page that writes megabytes into its address or title (with
     * history.pushState, or a title that keeps growing) leaves none of it in
     * your history, which Android reads whole each time Iris starts: longer
     * addresses are not kept, titles are clipped (as on Linux).
     */
    const val HISTORY_URL_MAX = 8192
    const val HISTORY_TITLE_MAX = 512

    /** at most n characters of s, never half of a surrogate pair */
    fun clip(s: String, n: Int): String {
        if (s.length <= n) return s
        var i = n
        if (i > 0 && Character.isHighSurrogate(s[i - 1])) i--
        return s.substring(0, i)
    }

    fun visit(url: String, title0: String) {
        if (!url.startsWith("http") || url.length > HISTORY_URL_MAX || Search.query(url) != null) return
        val title = clip(title0, HISTORY_TITLE_MAX)
        val h = history()
        val i = h.indexOfFirst { it.url == url }
        val now = System.currentTimeMillis()
        if (i >= 0) h[i] = h[i].copy(visits = h[i].visits + 1, last = now, title = title.ifEmpty { h[i].title })
        else h.add(Visit(url, title, 1, now))
        if (h.size > 1500) {
            h.sortByDescending { score(it, now) }
            while (h.size > 1200) h.removeAt(h.size - 1)
        }
        saveHistory()
    }

    private fun score(v: Visit, now: Long) = v.visits / (1.0 + (now - v.last) / 86_400_000.0 / 7)

    /** the sites you go to most, one entry per site */
    fun topSites(n: Int): List<Visit> {
        val now = System.currentTimeMillis()
        val seen = HashSet<String>()
        return history().sortedByDescending { score(it, now) }.mapNotNull { v ->
            val h = Search.host(v.url) ?: return@mapNotNull null
            if (seen.add(Search.site(h))) v.copy(url = "https://$h/") else null
        }.take(n)
    }

    fun clearHistory() {
        history().clear()
        saveHistory()
    }
}
