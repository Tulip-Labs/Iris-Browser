// SPDX-License-Identifier: GPL-3.0-only
package org.tulipanlabs.lite

import android.content.ContentValues
import android.content.Context
import android.content.SharedPreferences
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import java.util.concurrent.Executors

// Settings in SharedPreferences, history in SQLite (Android's own), and the
// open tabs so they come back after the app restarts.

/** a container: its own cookies and site data, apart from other tabs */
class Container(val name: String, val color: String)

class Settings(ctx: Context) {
    private val p: SharedPreferences = ctx.getSharedPreferences("lite", Context.MODE_PRIVATE)

    var theme: String
        get() = p.getString("theme", "sky") ?: "sky"
        set(v) = p.edit().putString("theme", v).apply()

    private fun flag(key: String, def: Boolean) = p.getBoolean(key, def)
    private fun setFlag(key: String, v: Boolean) = p.edit().putBoolean(key, v).apply()

    // the shield has no switches: always on (YouTube aside, see Pages.shieldOn)
    val shields: Boolean get() = true
    val lists: Boolean get() = true
    val cookies: Boolean get() = true
    val cleanLinks: Boolean get() = true
    var httpsOnly: Boolean get() = flag("httpsOnly", true); set(v) = setFlag("httpsOnly", v)
    var farble: Boolean get() = flag("farble", true); set(v) = setFlag("farble", v)
    val youtube: Boolean get() = true
    var youtubeLight: Boolean get() = flag("youtubeLight", true); set(v) = setFlag("youtubeLight", v)
    var desktop: Boolean get() = flag("desktop", false); set(v) = setFlag("desktop", v)

    var blockedTotal: Long
        get() = p.getLong("blockedTotal", 0)
        set(v) = p.edit().putLong("blockedTotal", v).apply()

    /** sites where the shield is off */
    var shieldOff: Set<String>
        get() = p.getStringSet("shieldOff", emptySet())?.toSet() ?: emptySet()
        set(v) = p.edit().putStringSet("shieldOff", v).apply()

    fun listIds(): Set<String> {
        if (!lists) return emptySet()
        val s = mutableSetOf("easylist", "easyprivacy", "ublock")
        if (cookies) s.add("cookies")
        return s
    }

    /** the open tabs (not private ones), restored on the next start */
    var session: List<String>
        get() = (p.getString("session", "") ?: "").split('\n').filter { it.isNotBlank() }
        set(v) = p.edit().putString("session", v.joinToString("\n")).apply()
    var sessionIndex: Int
        get() = p.getInt("sessionIndex", 0)
        set(v) = p.edit().putInt("sessionIndex", v).apply()


    /** containers: a name and a color each ("name\tcolor" lines) */
    var containers: List<Container>
        get() {
            val raw = p.getString("containers", null) ?: return listOf(Container("Work", "blue"), Container("Personal", "orange"))
            return raw.split('\n').mapNotNull { l ->
                val f = l.split('\t')
                if (f.isEmpty() || f[0].isBlank()) null else Container(f[0], f.getOrElse(1) { "blue" })
            }
        }
        set(v) = p.edit().putString("containers", v.joinToString("\n") { it.name.replace('\n', ' ').replace('\t', ' ') + "\t" + it.color }).apply()

    /** the container of each kept tab, in the order of [session] ("" = none) */
    var sessionContainers: List<String>
        get() = (p.getString("sessionContainers", "") ?: "").split('\n')
        set(v) = p.edit().putString("sessionContainers", v.joinToString("\n")).apply()

    // ---- sync with Iris on a computer (see Sync.kt) ----

    private fun str(key: String) = p.getString(key, "") ?: ""
    private fun setStr(key: String, v: String) = p.edit().putString(key, v).apply()

    var syncKey: String get() = str("syncKey"); set(v) = setStr("syncKey", v)
    var syncHost: String get() = str("syncHost"); set(v) = setStr("syncHost", v)
    var syncPc: String get() = str("syncPc"); set(v) = setStr("syncPc", v)
    var syncName: String get() = str("syncName"); set(v) = setStr("syncName", v)
    var pcTabs: String get() = str("pcTabs"); set(v) = setStr("pcTabs", v)
    var syncPort: Int
        get() = p.getInt("syncPort", 47600)
        set(v) = p.edit().putInt("syncPort", v).apply()
    var syncAt: Long
        get() = p.getLong("syncAt", 0)
        set(v) = p.edit().putLong("syncAt", v).apply()
    /** when the palette was last chosen, in seconds (the newest choice wins) */
    var themeAt: Long
        get() = p.getLong("themeAt", 0)
        set(v) = p.edit().putLong("themeAt", v).apply()
    /** this phone's id for the computer */
    val device: String
        get() {
            var d = str("device")
            if (d.isEmpty()) {
                d = java.util.UUID.randomUUID().toString().replace("-", "").take(16)
                setStr("device", d)
            }
            return d
        }
}

class Entry(val url: String, val title: String, val visits: Int, val last: Long)

/** Visited pages, for the address bar's suggestions. Never private tabs. */
class History(ctx: Context) : SQLiteOpenHelper(ctx, "history.db", null, 1) {
    private val io = Executors.newSingleThreadExecutor()

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE visits (url TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '', visits INTEGER NOT NULL DEFAULT 1, last INTEGER NOT NULL)")
        db.execSQL("CREATE INDEX visits_last ON visits(last)")
    }

    override fun onUpgrade(db: SQLiteDatabase, old: Int, new: Int) {}

    fun add(url: String, title: String) {
        if (url.isEmpty() || !url.startsWith("http")) return
        io.execute {
            try {
                val db = writableDatabase
                val now = System.currentTimeMillis() / 1000
                val v = ContentValues()
                v.put("url", url)
                v.put("title", title)
                v.put("last", now)
                if (db.insertWithOnConflict("visits", null, v, SQLiteDatabase.CONFLICT_IGNORE) == -1L) {
                    if (title.isNotEmpty()) db.execSQL("UPDATE visits SET visits = visits + 1, last = ?, title = ? WHERE url = ?", arrayOf<Any>(now, title, url))
                    else db.execSQL("UPDATE visits SET visits = visits + 1, last = ? WHERE url = ?", arrayOf<Any>(now, url))
                }
            } catch (e: Exception) {
            }
        }
    }

    fun title(url: String, title: String) {
        if (title.isEmpty()) return
        io.execute {
            try { writableDatabase.execSQL("UPDATE visits SET title = ? WHERE url = ?", arrayOf<Any>(title, url)) } catch (e: Exception) {}
        }
    }

    /** pages whose address or title contains text, best first (call off the UI thread) */
    fun suggest(text: String, n: Int): List<Entry> {
        val out = ArrayList<Entry>()
        try {
            val like = "%" + text.replace("%", "").replace("_", "") + "%"
            readableDatabase.rawQuery(
                "SELECT url, title, visits, last FROM visits WHERE url LIKE ? OR title LIKE ? ORDER BY visits * 1.0 / (1 + (strftime('%s','now') - last) / 604800.0) DESC LIMIT ?",
                arrayOf(like, like, n.toString()),
            ).use { c ->
                while (c.moveToNext()) out.add(Entry(c.getString(0), c.getString(1), c.getInt(2), c.getLong(3)))
            }
        } catch (e: Exception) {
        }
        return out
    }

    fun clear() {
        io.execute { try { writableDatabase.execSQL("DELETE FROM visits") } catch (e: Exception) {} }
    }

    /** the pages visited last, newest first (call off the UI thread) */
    fun recent(n: Int): List<Entry> {
        val out = ArrayList<Entry>()
        try {
            readableDatabase.rawQuery("SELECT url, title, visits, last FROM visits ORDER BY last DESC LIMIT ?", arrayOf(n.toString())).use { c ->
                while (c.moveToNext()) out.add(Entry(c.getString(0), c.getString(1), c.getInt(2), c.getLong(3)))
            }
        } catch (e: Exception) {
        }
        return out
    }

    /** visits known to another device: the later date and the larger count win */
    fun merge(list: List<Entry>) {
        io.execute {
            try {
                val db = writableDatabase
                db.beginTransaction()
                try {
                    for (e in list) {
                        if (!e.url.startsWith("http")) continue
                        db.execSQL(
                            "INSERT INTO visits (url, title, visits, last) VALUES (?, ?, ?, ?) ON CONFLICT(url) DO UPDATE SET " +
                                "visits = MAX(visits, excluded.visits), last = MAX(last, excluded.last), " +
                                "title = CASE WHEN title = '' THEN excluded.title ELSE title END",
                            arrayOf<Any>(e.url, e.title, maxOf(1, e.visits), e.last),
                        )
                    }
                    db.setTransactionSuccessful()
                } finally {
                    db.endTransaction()
                }
            } catch (e: Exception) {
            }
        }
    }
}
