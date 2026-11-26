package org.tulipanlabs.iris

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import android.webkit.URLUtil
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.net.HttpURLConnection
import java.net.URL

/** one download, as the downloads manager shows it */
class Download(val name: String, val mime: String, total: Long) {
    var knownTotal by mutableStateOf(total)
    val total: Long get() = knownTotal
    var received by mutableStateOf(0L)
    var done by mutableStateOf(false)
    var failed by mutableStateOf(false)
    var uri by mutableStateOf<Uri?>(null)
    @Volatile var cancelled = false
    val progress: Float get() = if (total > 0) (received.toFloat() / total).coerceIn(0f, 1f) else 0f
}

/**
 * Downloads go into the phone's Downloads folder (through MediaStore, so no
 * storage permission is needed) and are listed in Iris's downloads manager.
 */
object Downloads {
    val list = mutableStateListOf<Download>()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** a file a page offers: fetched with the page's cookies, into Downloads */
    fun fetch(c: Context, url: String, agent: String?, disposition: String?, mimeType: String?, length: Long, cookies: String?, referer: String, suggested: String? = null) {
        var name = (suggested?.takeIf { it.isNotBlank() } ?: URLUtil.guessFileName(url, disposition, mimeType)).replace('/', '_').ifEmpty { "download" }
        val mime = mimeType?.substringBefore(';')?.trim()?.takeIf { it.isNotEmpty() && it != "application/octet-stream" }
            ?: MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substringAfterLast('.', "")) ?: "application/octet-stream"
        // only from the web: a file: or content: address would copy Iris's
        // own files (or another app's) into the public Downloads folder
        if (!isWeb(url)) {
            android.widget.Toast.makeText(c, "This download can't be saved from here", android.widget.Toast.LENGTH_SHORT).show()
            return
        }
        val d = Download(name, mime, length)
        list.add(0, d)
        val main = android.os.Handler(c.mainLooper)
        scope.launch {
            val resolver = c.contentResolver
            var uri: Uri? = null
            try {
                val conn = open(url, agent, cookies, referer)
                val expect = conn.contentLengthLong
                val total = if (length > 0) length else expect
                var got = 0L
                val values = ContentValues().apply {
                    put(MediaStore.Downloads.DISPLAY_NAME, name)
                    put(MediaStore.Downloads.MIME_TYPE, mime)
                    put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                    put(MediaStore.Downloads.IS_PENDING, 1)
                }
                uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values) ?: throw IllegalStateException("no place in Downloads")
                conn.inputStream.use { body ->
                    resolver.openOutputStream(uri)!!.use { out ->
                        val buf = ByteArray(64 * 1024)
                        var n = 0L
                        var last = 0L
                        while (isActive && !d.cancelled) {
                            val k = body.read(buf)
                            if (k < 0) break
                            out.write(buf, 0, k)
                            n += k
                            if (n - last > 256 * 1024) { last = n; val v = n; main.post { d.received = v; d.knownTotal = total } }
                        }
                        val v = n
                        got = n
                        main.post { d.received = v; d.knownTotal = total }
                    }
                }
                conn.disconnect()
                // a connection that ends early is a broken file, not a finished one
                if (!d.cancelled && expect > 0 && got < expect) throw IllegalStateException("the download stopped part way")
                if (d.cancelled) {
                    resolver.delete(uri, null, null)
                    main.post { d.failed = true }
                } else {
                    resolver.update(uri, ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null)
                    val u = uri
                    main.post { d.uri = u; d.done = true; unseen++ }
                }
            } catch (e: Exception) {
                uri?.let { runCatching { resolver.delete(it, null, null) } }
                main.post { d.failed = true }
            }
        }
    }

    /** at most this many redirects before a download gives up */
    const val MAX_REDIRECTS = 10

    /**
     * The download's answer, its redirects followed here rather than by
     * HttpURLConnection, which stops at one from http to https (or back) and
     * sends the page's cookies on to whatever host a redirect names. Every
     * hop must be a web address; the cookies go only to the page's own host.
     */
    private fun open(url: String, agent: String?, cookies: String?, referer: String): HttpURLConnection {
        val first = URL(url)
        var at = first
        repeat(MAX_REDIRECTS + 1) {
            if (!isWeb(at.toString())) throw IllegalStateException("not a web address")
            val conn = at.openConnection() as HttpURLConnection
            conn.instanceFollowRedirects = false
            conn.connectTimeout = 20000
            conn.readTimeout = 60000
            agent?.let { conn.setRequestProperty("User-Agent", it) }
            if (cookies != null && cookiesMayGo(at, first)) conn.setRequestProperty("Cookie", cookies)
            if (referer.startsWith("http")) conn.setRequestProperty("Referer", referer)
            val code = conn.responseCode
            if (code in 200..299) return conn
            val next = if (code in 300..399) conn.getHeaderField("Location") else null
            conn.disconnect()
            if (next == null) throw IllegalStateException("HTTP $code")
            at = redirect(at, next) ?: throw IllegalStateException("not a web address")
        }
        throw IllegalStateException("too many redirects")
    }

    /** where a redirect's Location leads from an address, if it stays on the web */
    fun redirect(from: URL, location: String): URL? {
        val u = runCatching { URL(from, location.trim()) }.getOrNull() ?: return null
        return u.takeIf { isWeb(it.toString()) }
    }

    /**
     * Whether the page's cookies may go with a request to `to`: only to the
     * host they came from, and never from https down to plain http (a
     * secure cookie would travel unencrypted).
     */
    fun cookiesMayGo(to: URL, from: URL): Boolean =
        to.host.equals(from.host, true) && (to.protocol.equals("https", true) || from.protocol.equals("http", true))

    /** an address Iris downloads from: http or https, with a host */
    fun isWeb(url: String): Boolean {
        val u = runCatching { java.net.URI(url) }.getOrNull() ?: return false
        val s = u.scheme?.lowercase() ?: return false
        return (s == "http" || s == "https") && !u.host.isNullOrEmpty()
    }

    fun open(c: Context, d: Download) {
        val u = d.uri ?: return
        val i = Intent(Intent.ACTION_VIEW).setDataAndType(u, d.mime)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        runCatching { c.startActivity(Intent.createChooser(i, d.name).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
    }

    fun remove(c: Context, d: Download) {
        d.cancelled = true
        d.uri?.let { runCatching { c.contentResolver.delete(it, null, null) } }
        list.remove(d)
    }

    fun clearFinished() { list.removeAll { it.done || it.failed } }

    val active: Int get() = list.count { !it.done && !it.failed }

    /** finished since you last opened the downloads: the button's number */
    var unseen by mutableIntStateOf(0)
        private set

    /** the downloads were looked at */
    fun seen() { unseen = 0 }
}
