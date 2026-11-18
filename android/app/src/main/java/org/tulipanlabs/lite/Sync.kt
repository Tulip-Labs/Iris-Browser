// SPDX-License-Identifier: GPL-3.0-only
package org.tulipanlabs.lite

import android.net.Uri
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.Inet4Address
import java.net.NetworkInterface
import java.net.URL
import java.security.SecureRandom
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

// Sync with Iris on a computer, with no server in between: when both are
// on the same network, the phone and the computer trade history, open tabs
// and the palette. Everything is sealed with the key from the pairing
// (AES-256-GCM), so nobody else on the network can read or change it.

/** an open tab on the computer */
class PcTab(val url: String, val title: String)

object Sync {
    private const val AAD = "litego-sync-1" // the computer uses the same; kept across the rename
    private const val FIRST_PORT = 47600

    fun paired(set: Settings): Boolean = set.syncKey.length == 64 && set.syncHost.isNotEmpty()

    /** iris://pair?h= (litego:// from Iris 1.0.19 and older) <address>&p=<port>&k=<key>&d=<computer id>&n=<its name> */
    fun pair(set: Settings, uri: Uri): Boolean {
        if ((uri.scheme != "iris" && uri.scheme != "litego") || uri.host != "pair") return false
        val key = uri.getQueryParameter("k") ?: return false
        val host = uri.getQueryParameter("h") ?: return false
        if (!Regex("[0-9a-f]{64}").matches(key) || !Regex("[0-9.]{7,15}").matches(host)) return false
        set.syncKey = key
        set.syncHost = host
        set.syncPort = uri.getQueryParameter("p")?.toIntOrNull()?.takeIf { it in 1024..65535 } ?: FIRST_PORT
        set.syncPc = uri.getQueryParameter("d") ?: ""
        set.syncName = uri.getQueryParameter("n") ?: "the computer"
        set.syncAt = 0
        return true
    }

    fun unpair(set: Settings) {
        set.syncKey = ""
        set.syncHost = ""
        set.syncPc = ""
        set.pcTabs = ""
        set.syncAt = 0
    }

    fun pcTabs(set: Settings): List<PcTab> {
        val out = ArrayList<PcTab>()
        try {
            val a = JSONArray(set.pcTabs)
            for (i in 0 until a.length()) {
                val o = a.getJSONObject(i)
                out.add(PcTab(o.getString("url"), o.optString("title")))
            }
        } catch (e: Exception) {
        }
        return out
    }

    private fun cipher(mode: Int, keyHex: String, nonce: ByteArray): Cipher {
        val key = ByteArray(32) { keyHex.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(mode, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        c.updateAAD(AAD.toByteArray())
        return c
    }

    fun seal(keyHex: String, plain: ByteArray): ByteArray {
        val nonce = ByteArray(12)
        SecureRandom().nextBytes(nonce)
        return nonce + cipher(Cipher.ENCRYPT_MODE, keyHex, nonce).doFinal(plain)
    }

    fun open(keyHex: String, data: ByteArray): ByteArray {
        val nonce = data.copyOfRange(0, 12)
        return cipher(Cipher.DECRYPT_MODE, keyHex, nonce).doFinal(data, 12, data.size - 12)
    }

    /** this phone's own address on the Wi-Fi, or null */
    private fun ownAddress(): String? {
        try {
            for (ni in NetworkInterface.getNetworkInterfaces()) {
                if (!ni.isUp || ni.isLoopback) continue
                for (a in ni.inetAddresses) {
                    if (a is Inet4Address && a.isSiteLocalAddress) return a.hostAddress
                }
            }
        } catch (e: Exception) {
        }
        return null
    }

    /** is the paired computer at host:port? */
    private fun hello(host: String, port: Int, pc: String, timeout: Int): Boolean {
        return try {
            val c = URL("http://$host:$port/sync/hello").openConnection() as HttpURLConnection
            c.connectTimeout = timeout
            c.readTimeout = timeout
            val body = c.inputStream.use { it.readBytes().toString(Charsets.UTF_8) }
            c.disconnect()
            val o = JSONObject(body)
            (o.optString("app") == "iris" || o.optString("app") == "litego") && (pc.isEmpty() || o.optString("id") == pc)
        } catch (e: Exception) {
            false
        }
    }

    /** the computer's address may have changed: look for it on this network */
    private fun find(set: Settings): String? {
        val own = ownAddress() ?: return null
        val base = own.substringBeforeLast('.')
        val found = AtomicReference<String?>(null)
        val pool = Executors.newFixedThreadPool(40)
        for (n in 1..254) {
            val host = "$base.$n"
            if (host == own) continue
            pool.execute {
                if (found.get() == null && hello(host, set.syncPort, set.syncPc, 400)) found.compareAndSet(null, host)
            }
        }
        pool.shutdown()
        try {
            pool.awaitTermination(8, TimeUnit.SECONDS)
        } catch (e: Exception) {
        }
        pool.shutdownNow()
        return found.get()
    }

    /**
     * Trades state with the computer. Call off the UI thread. Returns null
     * when the computer is not on this network, else whether the palette changed.
     */
    fun run(set: Settings, hist: History, tabs: List<PcTab>): Boolean? {
        if (!paired(set)) return null
        var host = set.syncHost
        if (!hello(host, set.syncPort, set.syncPc, 1500)) {
            host = find(set) ?: return null
            set.syncHost = host
        }
        return try {
            val me = JSONObject()
            me.put("device", set.device)
            me.put("name", (Build.MANUFACTURER.replaceFirstChar { it.uppercase() } + " " + Build.MODEL).trim())
            me.put("theme", set.theme)
            me.put("themeAt", set.themeAt)
            val jt = JSONArray()
            for (t in tabs) jt.put(JSONObject().put("url", t.url).put("title", t.title))
            me.put("tabs", jt)
            val jh = JSONArray()
            for (e in hist.recent(500)) jh.put(JSONObject().put("u", e.url).put("t", e.title).put("v", e.visits).put("l", e.last))
            me.put("history", jh)

            val c = URL("http://$host:${set.syncPort}/sync/x").openConnection() as HttpURLConnection
            c.connectTimeout = 3000
            c.readTimeout = 15000
            c.requestMethod = "POST"
            c.doOutput = true
            c.setRequestProperty("Content-Type", "application/octet-stream")
            c.outputStream.use { it.write(seal(set.syncKey, me.toString().toByteArray())) }
            if (c.responseCode != 200) {
                c.disconnect()
                return null
            }
            val sealed = c.inputStream.use { it.readBytes() }
            c.disconnect()
            val pc = JSONObject(open(set.syncKey, sealed).toString(Charsets.UTF_8))

            val h = pc.optJSONArray("history")
            if (h != null) {
                val list = ArrayList<Entry>(h.length())
                for (i in 0 until h.length()) {
                    val o = h.getJSONObject(i)
                    list.add(Entry(o.getString("u"), o.optString("t"), o.optInt("v", 1), o.optLong("l")))
                }
                hist.merge(list)
            }
            val t = pc.optJSONArray("tabs")
            val keep = JSONArray()
            if (t != null) for (i in 0 until minOf(t.length(), 100)) keep.put(t.getJSONObject(i))
            set.pcTabs = keep.toString()
            set.syncAt = System.currentTimeMillis()

            var changed = false
            val theme = pc.optString("theme")
            val at = pc.optLong("themeAt")
            if (at > set.themeAt && theme != set.theme && Palette.all.any { it.id == theme }) {
                set.theme = theme
                changed = true
            }
            if (at > set.themeAt) set.themeAt = at
            changed
        } catch (e: Exception) {
            null
        }
    }
}
