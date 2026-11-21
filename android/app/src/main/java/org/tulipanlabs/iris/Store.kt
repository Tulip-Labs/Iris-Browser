package org.tulipanlabs.iris

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** a container: a world of its own (cookies, storage, cache, sign-ins) */
data class Container(val id: String, val name: String, val color: Long) {
    companion object {
        const val PRIVATE = "private"
        val palette = listOf(0xFF0A84FF, 0xFFFF9F0A, 0xFF30D158, 0xFFFF375F, 0xFFBF5AF2, 0xFF64D2FF, 0xFFFFD60A, 0xFFAC8E68)
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
            containers = listOf("Personal", "Work", "Shopping", "Banking").mapIndexed { i, n ->
                Container(UUID.randomUUID().toString(), n, Container.palette[i])
            }
        }
    }

    var shields: Boolean
        get() = p.getBoolean("shields", true)
        set(v) = p.edit().putBoolean("shields", v).apply()

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
            (0 until a.length()).map { a.getJSONObject(it).let { o -> Container(o.getString("id"), o.getString("name"), o.getLong("color")) } }
        }.getOrDefault(emptyList())
        set(v) {
            val a = JSONArray()
            v.forEach { a.put(JSONObject().put("id", it.id).put("name", it.name).put("color", it.color)) }
            p.edit().putString("containers", a.toString()).apply()
        }

    fun container(id: String?): Container? = when (id) {
        null -> null
        Container.PRIVATE -> Container(Container.PRIVATE, "Private", 0xFF5E5CE6)
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

    fun visit(url: String, title: String) {
        if (!url.startsWith("http") || Search.query(url) != null) return
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
