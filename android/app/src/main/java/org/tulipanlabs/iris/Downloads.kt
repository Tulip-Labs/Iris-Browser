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
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import org.mozilla.geckoview.WebResponse

/** one download, as the downloads manager shows it */
class Download(val name: String, val mime: String, val total: Long) {
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

    private fun fileName(r: WebResponse): Pair<String, String> {
        val disposition = r.headers["Content-Disposition"] ?: r.headers["content-disposition"]
        val type = (r.headers["Content-Type"] ?: r.headers["content-type"])?.substringBefore(';')?.trim()
        var name = URLUtil.guessFileName(r.uri, disposition, type)
        val mime = type ?: MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substringAfterLast('.', "")) ?: "application/octet-stream"
        name = name.replace('/', '_').ifEmpty { "download" }
        return name to mime
    }

    fun save(c: Context, r: WebResponse, private: Boolean) {
        val body = r.body ?: return
        val (name, mime) = fileName(r)
        val total = (r.headers["Content-Length"] ?: r.headers["content-length"])?.toLongOrNull() ?: -1
        val d = Download(name, mime, total)
        android.os.Handler(c.mainLooper).post { list.add(0, d) }
        scope.launch {
            val resolver = c.contentResolver
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, name)
                put(MediaStore.Downloads.MIME_TYPE, mime)
                put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            if (uri == null) { d.failed = true; body.close(); return@launch }
            try {
                resolver.openOutputStream(uri)?.use { out ->
                    val buf = ByteArray(64 * 1024)
                    var n = 0L
                    var last = 0L
                    while (isActive && !d.cancelled) {
                        val k = body.read(buf)
                        if (k < 0) break
                        out.write(buf, 0, k)
                        n += k
                        if (n - last > 256 * 1024) { last = n; val v = n; android.os.Handler(c.mainLooper).post { d.received = v } }
                    }
                    val v = n
                    android.os.Handler(c.mainLooper).post { d.received = v }
                }
                body.close()
                if (d.cancelled) {
                    resolver.delete(uri, null, null)
                    android.os.Handler(c.mainLooper).post { d.failed = true }
                } else {
                    resolver.update(uri, ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null)
                    android.os.Handler(c.mainLooper).post { d.uri = uri; d.done = true }
                }
            } catch (e: Exception) {
                runCatching { resolver.delete(uri, null, null) }
                android.os.Handler(c.mainLooper).post { d.failed = true }
            }
        }
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
}
