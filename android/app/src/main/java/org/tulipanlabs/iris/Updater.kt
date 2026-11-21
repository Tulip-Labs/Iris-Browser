package org.tulipanlabs.iris

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build
import android.provider.Settings
import android.widget.Toast
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/** a newer Iris on GitHub */
data class Release(val version: String, val apk: String, val page: String)

/**
 * Auto-update: Iris asks GitHub once a day for a newer release, offers it,
 * downloads the APK and has Android install it over itself. Android installs
 * an update only when it is signed with the same key as the installed app,
 * so every release APK must be signed with Iris's release key.
 */
object Updater {
    private const val API = "https://api.github.com/repos/Tulip-Labs/Iris-Browser/releases/latest"
    private const val ACTION = "org.tulipanlabs.iris.INSTALLED"

    var available by mutableStateOf<Release?>(null)
    var downloading by mutableStateOf(false)
    var progress by mutableFloatStateOf(0f)

    fun newer(a: String, b: String): Boolean {
        val x = a.split('.').map { it.toIntOrNull() ?: 0 }
        val y = b.split('.').map { it.toIntOrNull() ?: 0 }
        for (i in 0 until maxOf(x.size, y.size)) {
            val p = x.getOrElse(i) { 0 }
            val q = y.getOrElse(i) { 0 }
            if (p != q) return p > q
        }
        return false
    }

    suspend fun check(force: Boolean = false): Release? = withContext(Dispatchers.IO) {
        if (!force && System.currentTimeMillis() - Store.lastUpdateCheck < 86_400_000) return@withContext null
        runCatching {
            val c = URL(API).openConnection() as HttpURLConnection
            c.setRequestProperty("Accept", "application/vnd.github+json")
            c.setRequestProperty("User-Agent", "Iris-Android/${BuildConfig.VERSION_NAME}")
            c.connectTimeout = 15000
            c.readTimeout = 20000
            val body = c.inputStream.bufferedReader().use { it.readText() }
            c.disconnect()
            Store.lastUpdateCheck = System.currentTimeMillis()
            val j = JSONObject(body)
            val v = j.getString("tag_name").removePrefix("v")
            val assets = j.getJSONArray("assets")
            val apk = (0 until assets.length()).map { assets.getJSONObject(it) }
                .firstOrNull { it.getString("name").endsWith(".apk") }?.getString("browser_download_url")
            if (apk != null && newer(v, BuildConfig.VERSION_NAME)) Release(v, apk, j.optString("html_url")) else null
        }.getOrNull().also { r -> withContext(Dispatchers.Main) { available = r } }
    }

    /** downloads the release and hands it to Android's installer */
    suspend fun install(c: Context, r: Release) {
        if (!c.packageManager.canRequestPackageInstalls()) {
            // Android asks once whether Iris may install its own updates
            c.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, android.net.Uri.parse("package:" + c.packageName))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            return
        }
        downloading = true
        progress = 0f
        try {
            withContext(Dispatchers.IO) {
                val installer = c.packageManager.packageInstaller
                val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
                params.setAppPackageName(c.packageName)
                if (Build.VERSION.SDK_INT >= 31) params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
                val id = installer.createSession(params)
                installer.openSession(id).use { s ->
                    val conn = URL(r.apk).openConnection() as HttpURLConnection
                    conn.instanceFollowRedirects = true
                    conn.setRequestProperty("User-Agent", "Iris-Android/${BuildConfig.VERSION_NAME}")
                    val total = conn.contentLengthLong
                    conn.inputStream.use { input ->
                        s.openWrite("iris.apk", 0, total).use { out ->
                            val buf = ByteArray(128 * 1024)
                            var n = 0L
                            while (true) {
                                val k = input.read(buf)
                                if (k < 0) break
                                out.write(buf, 0, k)
                                n += k
                                if (total > 0) withContext(Dispatchers.Main) { progress = n.toFloat() / total }
                            }
                            s.fsync(out)
                        }
                    }
                    val pi = PendingIntent.getBroadcast(c, id, Intent(c, UpdateReceiver::class.java).setAction(ACTION),
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE)
                    s.commit(pi.intentSender)
                }
            }
        } catch (e: Exception) {
            Toast.makeText(c, "The update did not download: ${e.message}", Toast.LENGTH_LONG).show()
        } finally {
            downloading = false
        }
    }
}

/** Android's answer about an update: it may need you to confirm */
class UpdateReceiver : BroadcastReceiver() {
    override fun onReceive(c: Context, i: Intent) {
        when (i.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                @Suppress("DEPRECATION")
                val confirm = if (Build.VERSION.SDK_INT >= 33) i.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java) else i.getParcelableExtra(Intent.EXTRA_INTENT)
                confirm?.let { c.startActivity(it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
            }
            PackageInstaller.STATUS_SUCCESS -> {}
            else -> {
                val msg = i.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: "unknown"
                Toast.makeText(c, "Iris could not update: $msg", Toast.LENGTH_LONG).show()
            }
        }
    }
}
