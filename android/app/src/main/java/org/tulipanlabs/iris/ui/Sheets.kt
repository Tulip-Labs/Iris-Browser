@file:OptIn(ExperimentalFoundationApi::class)

package org.tulipanlabs.iris.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch
import org.tulipanlabs.iris.BrowserModel
import org.tulipanlabs.iris.BuildConfig
import org.tulipanlabs.iris.Container
import org.tulipanlabs.iris.Downloads
import org.tulipanlabs.iris.Pages
import org.tulipanlabs.iris.Pressed
import org.tulipanlabs.iris.Search
import org.tulipanlabs.iris.ShieldLevel
import org.tulipanlabs.iris.Shields
import org.tulipanlabs.iris.Store
import org.tulipanlabs.iris.Updater
import java.util.UUID

/** Iris Shields: for this site, everywhere, and how hard */
@Composable
fun ShieldsSheet(model: BrowserModel, open: Boolean, onClose: () -> Unit) {
    val p = LocalPalette.current
    val t = model.current
    var everywhere by remember(open) { mutableStateOf(Store.shields) }
    var level by remember(open) { mutableStateOf(Store.shieldLevel) }
    val site = t?.url?.let { Search.host(it) }?.let { Search.site(it) }
    var here by remember(open, site) { mutableStateOf(t?.let { model.shieldsFor(it.url) } ?: true) }
    var audio by remember(open) { mutableStateOf(Store.backgroundAudio) }
    GlassSheet(open, onClose, "Shields") {
        Txt("Ads and trackers are stopped inside Chromium, before a request leaves the phone, as in Brave. Cookies never go to other sites.",
            Modifier.padding(horizontal = 24.dp), size = 14.sp, color = p.ink2)
        if (t != null && t.blocked > 0) {
            Txt("${t.blocked} stopped on this page", Modifier.padding(horizontal = 24.dp, vertical = 6.dp), size = 14.sp, weight = FontWeight.SemiBold, color = p.accent)
        }
        Spacer(Modifier.height(6.dp))
        if (site != null && everywhere) {
            GlassRow(if (here) Glyph.SHIELD_ON else Glyph.SHIELD, site, sub = if (here) "Protected" else "Shields are off here") {
                GlassToggle(here) { here = it; t?.let(model::toggleSiteShields) }
            }
        }
        GlassRow(Glyph.GLOBE, "Everywhere") {
            GlassToggle(everywhere) { everywhere = it; Store.shields = it; model.shieldsChanged() }
        }
        if (everywhere) {
            SectionTitle("How hard")
            for (l in ShieldLevel.entries) {
                GlassRow(if (l == level) Glyph.CHECK else null, l.title, {
                    if (l != level) {
                        level = l
                        Store.shieldLevel = l
                        Shields.levelChanged()
                    }
                }, sub = l.hint, tint = p.accent)
            }
            Txt(level.about, Modifier.padding(horizontal = 24.dp, vertical = 6.dp), size = 13.sp, color = p.ink2)
            Txt("If a site looks wrong, turn Shields off for it above.", Modifier.padding(horizontal = 24.dp), size = 13.sp, color = p.ink2)
        }
        Separator()
        SectionTitle("Background audio")
        GlassRow(Glyph.MUSIC, "Background audio", sub = if (audio) "Sound keeps playing with the screen off or Iris behind another app" else "Sound stops when Iris leaves the screen") {
            GlassToggle(audio) { audio = it; model.applyBackgroundAudio(it) }
        }
        Txt("Iris asks for the notification permission the first time audio plays, so the playback controls can show. Saying no changes nothing about the sound.",
            Modifier.padding(horizontal = 24.dp, vertical = 6.dp), size = 13.sp, color = p.ink2)
    }
}

/** containers: worlds apart, each with its own cookies, storage and sign-ins */
@Composable
fun ContainersSheet(model: BrowserModel, open: Boolean, onClose: () -> Unit) {
    val p = LocalPalette.current
    var list by remember(open) { mutableStateOf(Store.containers) }
    var naming by remember { mutableStateOf(false) }
    var removing by remember { mutableStateOf<Container?>(null) }
    val t = model.current
    GlassSheet(open && !naming && removing == null, onClose, "Containers") {
        SectionTitle("New tab in")
        GlassRow(Glyph.GLOBE, "No container", { onClose(); model.newTab() })
        list.forEach { c ->
            GlassRow(Glyphs.container(c.icon), c.name, { onClose(); model.newTab(container = c.id) }, tint = Color(c.color)) {
                GlassButton(Glyph.TRASH, "Remove ${c.name}", { removing = c }, size = 36.dp, clear = true, tint = p.ink2)
            }
        }
        GlassRow(Glyph.EYE_OFF, "Private", { onClose(); model.newTab(container = Container.PRIVATE) })
        if (t != null && t.url.isNotEmpty()) {
            Separator()
            SectionTitle("Open this page in")
            list.filter { it.id != t.container }.forEach { c ->
                GlassRow(Glyphs.container(c.icon), c.name, { onClose(); model.newTab(t.url, c.id, after = t) }, tint = Color(c.color))
            }
        }
        Separator()
        GlassRow(Glyph.PLUS, "New container", { naming = true })
    }
    var name by remember(naming) { mutableStateOf("") }
    var icon by remember(naming) { mutableStateOf("star") }
    GlassDialog(naming, "New container", { naming = false }, "Add", {
        if (name.isNotBlank()) {
            val used = list.map { it.color }.toSet()
            val color = Container.palette.firstOrNull { it !in used } ?: Container.palette[list.size % Container.palette.size]
            list = list + Container(UUID.randomUUID().toString(), name.trim(), color, icon)
            Store.containers = list
        }
        naming = false
    }) {
        Box(Modifier.fillMaxWidth().glass(p, RoundedCornerShape(14.dp)).padding(horizontal = 14.dp, vertical = 12.dp)) {
            BasicTextField(name, { name = it }, singleLine = true, textStyle = TextStyle(fontSize = 16.sp, color = p.ink), cursorBrush = SolidColor(p.accent),
                decorationBox = { inner -> Box { if (name.isEmpty()) Txt("Name", color = p.ink2); inner() } })
        }
        Spacer(Modifier.height(12.dp))
        Container.icons.chunked(6).forEach { row ->
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                row.forEach { n ->
                    Box(
                        Modifier.padding(3.dp).size(38.dp).clip(RoundedCornerShape(12.dp))
                            .background(if (n == icon) p.accent.copy(alpha = 0.18f) else Color.Transparent)
                            .combinedClickable(interactionSource = remember { MutableInteractionSource() }, indication = null) { icon = n },
                        contentAlignment = Alignment.Center,
                    ) { GlyphIcon(Glyphs.container(n), size = 20.dp, tint = if (n == icon) p.accent else p.ink) }
                }
            }
        }
    }
    GlassDialog(removing != null, "Remove ${removing?.name ?: ""}?", { removing = null }, "Remove", {
        removing?.let { c ->
            model.removeContainer(c.id)
            list = list - c
            Store.containers = list
        }
        removing = null
    }, danger = true) {
        Txt("Its tabs close, and its cookies, sign-ins and site data are deleted.", color = p.ink2)
    }
}

/** the downloads */
@Composable
fun DownloadsSheet(open: Boolean, onClose: () -> Unit) {
    val p = LocalPalette.current
    val ctx = LocalContext.current
    GlassSheet(open, onClose, "Downloads") {
        if (Downloads.list.isEmpty()) {
            Txt("Nothing downloaded yet", Modifier.padding(24.dp), color = p.ink2)
        }
        Downloads.list.forEach { d ->
            val sub = when {
                d.failed -> if (d.cancelled) "Cancelled" else "Failed"
                d.done -> android.text.format.Formatter.formatShortFileSize(ctx, d.received) + " · Downloads folder"
                d.total > 0 -> android.text.format.Formatter.formatShortFileSize(ctx, d.received) + " of " + android.text.format.Formatter.formatShortFileSize(ctx, d.total)
                else -> android.text.format.Formatter.formatShortFileSize(ctx, d.received)
            }
            Column {
                GlassRow(Glyph.DOWNLOAD, d.name, { if (d.done) Downloads.open(ctx, d) }, sub = sub, tint = if (d.failed) p.danger else p.accent) {
                    GlassButton(Glyph.TRASH, if (d.done) "Delete" else "Cancel", { Downloads.remove(ctx, d) }, size = 36.dp, clear = true, tint = p.ink2)
                }
                if (!d.done && !d.failed) ProgressLine(if (d.total > 0) d.progress else null, Modifier.padding(start = 58.dp, end = 24.dp, bottom = 6.dp))
            }
        }
        if (Downloads.list.any { it.done || it.failed }) GlassRow(Glyph.CLOSE, "Clear finished", { Downloads.clearFinished() })
    }
}

/** what a long press on a link or an image offers */
@Composable
fun ContextSheet(model: BrowserModel, p0: Pressed?, onClose: () -> Unit) {
    val ctx = LocalContext.current
    val p = LocalPalette.current
    // the last one stays shown while the sheet slides away
    var last by remember { mutableStateOf<Pressed?>(null) }
    if (p0 != null) last = p0
    val pr = last
    fun copy(s: String) = (ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(ClipData.newPlainText("link", s))
    fun share(s: String) = ctx.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, s), null)
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    fun download(u: String, tabUrl: String) = Downloads.fetch(ctx, u, Pages.mobileAgent(), null, null, -1, null, tabUrl)
    GlassSheet(p0 != null, onClose) {
        if (pr != null) {
        val tab = pr.tab
        val link = pr.link?.takeIf { it.startsWith("http") }
        val src = pr.image?.takeIf { it.startsWith("http") }
        Txt(link ?: src ?: "", Modifier.padding(horizontal = 24.dp, vertical = 8.dp), size = 13.sp, color = p.ink2, maxLines = 2)
        if (link != null) {
            GlassRow(Glyph.OPEN, "Open in new tab", { onClose(); model.newTab(link, tab.container, after = tab, select = false) })
            Store.containers.filter { it.id != tab.container }.forEach { c ->
                GlassRow(Glyphs.container(c.icon), "Open in ${c.name}", { onClose(); model.newTab(link, c.id, after = tab) }, tint = Color(c.color))
            }
            GlassRow(Glyph.COPY, "Copy link", { onClose(); copy(link) })
            GlassRow(Glyph.SHARE, "Share link", { onClose(); share(link) })
            GlassRow(Glyph.DOWNLOAD, "Download link", { onClose(); download(link, tab.url) })
        }
        if (src != null) {
            GlassRow(Glyph.IMAGE, "Open image in new tab", { onClose(); model.newTab(src, tab.container, after = tab) })
            GlassRow(Glyph.COPY, "Copy image address", { onClose(); copy(src) })
            GlassRow(Glyph.DOWNLOAD, "Save image", { onClose(); download(src, tab.url) })
        }
    }
    }
}

/** a newer Iris: install it */
@Composable
fun UpdateDialog() {
    val r = Updater.available
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    val p = LocalPalette.current
    GlassDialog(r != null, "Iris ${r?.version ?: ""} is ready", { if (!Updater.downloading) Updater.available = null },
        if (Updater.downloading) "Downloading…" else "Update", { if (r != null && !Updater.downloading) scope.launch { Updater.install(ctx, r) } }, cancel = "Later") {
        if (Updater.downloading) ProgressLine(Updater.progress)
        else Txt("Iris downloads it from GitHub and Android installs it over this version. Your tabs stay.", color = p.ink2)
    }
}
