// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
package org.tulipanlabs.lite

import android.content.ContentValues
import android.content.Context
import android.content.SharedPreferences
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import java.util.concurrent.Executors

// Settings in SharedPreferences, history in SQLite (Android's own), and the
// open tabs so they come back after the app restarts.

class Settings(ctx: Context) {
    private val p: SharedPreferences = ctx.getSharedPreferences("lite", Context.MODE_PRIVATE)

    var theme: String
        get() = p.getString("theme", "crocus") ?: "crocus"
        set(v) = p.edit().putString("theme", v).apply()
    var mode: Mode
        get() = try { Mode.valueOf(p.getString("mode", "AI") ?: "AI") } catch (e: Exception) { Mode.AI }
        set(v) = p.edit().putString("mode", v.name).apply()

    private fun flag(key: String, def: Boolean) = p.getBoolean(key, def)
    private fun setFlag(key: String, v: Boolean) = p.edit().putBoolean(key, v).apply()

    var shields: Boolean get() = flag("shields", true); set(v) = setFlag("shields", v)
    var lists: Boolean get() = flag("lists", true); set(v) = setFlag("lists", v)
    var cookies: Boolean get() = flag("cookies", true); set(v) = setFlag("cookies", v)
    var cleanLinks: Boolean get() = flag("cleanLinks", true); set(v) = setFlag("cleanLinks", v)
    var httpsOnly: Boolean get() = flag("httpsOnly", true); set(v) = setFlag("httpsOnly", v)
    var farble: Boolean get() = flag("farble", true); set(v) = setFlag("farble", v)
    var youtube: Boolean get() = flag("youtube", true); set(v) = setFlag("youtube", v)
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
}
