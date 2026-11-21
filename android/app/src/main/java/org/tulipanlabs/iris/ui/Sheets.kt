package org.tulipanlabs.iris.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.Public
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.launch
import org.mozilla.geckoview.GeckoSession
import org.mozilla.geckoview.GeckoWebExecutor
import org.mozilla.geckoview.WebRequest
import org.tulipanlabs.iris.BrowserModel
import org.tulipanlabs.iris.Container
import org.tulipanlabs.iris.Download
import org.tulipanlabs.iris.Downloads
import org.tulipanlabs.iris.IrisApp
import org.tulipanlabs.iris.Search
import org.tulipanlabs.iris.Store
import org.tulipanlabs.iris.Tab
import org.tulipanlabs.iris.Updater
import java.util.UUID

@Composable
private fun SheetTitle(text: String) {
    Text(text, Modifier.padding(start = 24.dp, end = 24.dp, bottom = 8.dp), fontSize = 20.sp, fontWeight = FontWeight.SemiBold, color = Ink)
}

private val clearItem @Composable get() = ListItemDefaults.colors(containerColor = Color.Transparent)

/** Iris Shields: for this site, for everywhere, and uBlock Origin's lists */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ShieldsSheet(model: BrowserModel, onClose: () -> Unit) {
    val t = model.current
    var everywhere by remember { mutableStateOf(Store.shields) }
    var here by remember { mutableStateOf(t?.let { model.shieldsFor(it.url) } ?: true) }
    val site = t?.url?.let { Search.host(it) }?.let { Search.site(it) }
    ModalBottomSheet(onDismissRequest = onClose, sheetState = rememberModalBottomSheetState(), containerColor = Color(0xFFF8F7FC)) {
        SheetTitle("Shields")
        Text("Ads, trackers, fingerprinting, cookie banners and the pop-ups ads open are stopped inside the engine. Each site's cookies stay its own.",
            Modifier.padding(horizontal = 24.dp), fontSize = 14.sp, color = Ink.copy(alpha = 0.7f))
        Spacer(Modifier.height(8.dp))
        if (site != null && everywhere) {
            ListItem(
                headlineContent = { Text(site) }, supportingContent = { Text(if (here) "Protected" else "Shields are off here") },
                trailingContent = { Switch(here, { here = it; t?.let(model::toggleSiteShields) }) }, colors = clearItem,
            )
        }
        ListItem(
            headlineContent = { Text("Everywhere") },
            trailingContent = { Switch(everywhere, { everywhere = it; IrisApp.instance.applyShields(it); t?.session?.reload() }) }, colors = clearItem,
        )
        val options = IrisApp.instance.ublock?.metaData?.optionsPageUrl
        if (options != null) {
            ListItem(
                headlineContent = { Text("Filter lists and rules") }, supportingContent = { Text("uBlock Origin") },
                leadingContent = { Icon(Icons.Filled.Tune, null) }, colors = clearItem,
                modifier = Modifier.clickable { onClose(); model.newTab(options) },
            )
        }
        Spacer(Modifier.navigationBarsPadding().height(16.dp))
    }
}

/** containers: worlds apart, each with its own cookies, storage and sign-ins */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ContainersSheet(model: BrowserModel, onClose: () -> Unit) {
    var list by remember { mutableStateOf(Store.containers) }
    var naming by remember { mutableStateOf(false) }
    var removing by remember { mutableStateOf<Container?>(null) }
    val t = model.current
    ModalBottomSheet(onDismissRequest = onClose, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = Color(0xFFF8F7FC)) {
        SheetTitle("Containers")
        Column(Modifier.verticalScroll(rememberScrollState())) {
            Text("New tab in", Modifier.padding(horizontal = 24.dp, vertical = 4.dp), fontSize = 13.sp, color = Ink.copy(alpha = 0.6f))
            ListItem(headlineContent = { Text("No container") }, leadingContent = { Icon(Icons.Filled.Public, null) }, colors = clearItem,
                modifier = Modifier.clickable { onClose(); model.newTab() })
            list.forEach { c ->
                ListItem(
                    headlineContent = { Text(c.name) },
                    leadingContent = { Box(Modifier.size(14.dp).clip(CircleShape).background(Color(c.color))) },
                    trailingContent = { IconButton(onClick = { removing = c }) { Icon(Icons.Filled.Delete, "Remove ${c.name}") } },
                    colors = clearItem,
                    modifier = Modifier.clickable { onClose(); model.newTab(container = c.id) },
                )
            }
            ListItem(headlineContent = { Text("Private") }, leadingContent = { Icon(Icons.Filled.VisibilityOff, null) }, colors = clearItem,
                modifier = Modifier.clickable { onClose(); model.newTab(container = Container.PRIVATE) })
            if (t != null && t.url.isNotEmpty()) {
                HorizontalDivider(Modifier.padding(vertical = 6.dp))
                Text("Open this page in", Modifier.padding(horizontal = 24.dp, vertical = 4.dp), fontSize = 13.sp, color = Ink.copy(alpha = 0.6f))
                list.filter { it.id != t.container }.forEach { c ->
                    ListItem(headlineContent = { Text(c.name) }, leadingContent = { Box(Modifier.size(14.dp).clip(CircleShape).background(Color(c.color))) },
                        colors = clearItem, modifier = Modifier.clickable { onClose(); model.newTab(t.url, c.id, after = t) })
                }
            }
            HorizontalDivider(Modifier.padding(vertical = 6.dp))
            ListItem(headlineContent = { Text("New container") }, leadingContent = { Icon(Icons.Filled.Add, null) }, colors = clearItem,
                modifier = Modifier.clickable { naming = true })
            Spacer(Modifier.navigationBarsPadding().height(16.dp))
        }
    }
    if (naming) {
        var name by remember { mutableStateOf("") }
        AlertDialog(
            onDismissRequest = { naming = false },
            title = { Text("New container") },
            text = { OutlinedTextField(name, { name = it }, singleLine = true, label = { Text("Name") }) },
            confirmButton = {
                TextButton(onClick = {
                    if (name.isNotBlank()) {
                        val used = list.map { it.color }.toSet()
                        val color = Container.palette.firstOrNull { it !in used } ?: Container.palette[list.size % Container.palette.size]
                        list = list + Container(UUID.randomUUID().toString(), name.trim(), color)
                        Store.containers = list
                    }
                    naming = false
                }) { Text("Add") }
            },
            dismissButton = { TextButton(onClick = { naming = false }) { Text("Cancel") } },
        )
    }
    removing?.let { c ->
        AlertDialog(
            onDismissRequest = { removing = null },
            title = { Text("Remove ${c.name}?") },
            text = { Text("Its tabs close, and its cookies, sign-ins and site data are deleted.") },
            confirmButton = {
                TextButton(onClick = {
                    model.tabs.filter { it.container == c.id }.forEach(model::close)
                    IrisApp.instance.runtime.storageController.clearDataForSessionContext(c.id)
                    list = list - c
                    Store.containers = list
                    removing = null
                }) { Text("Remove", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { removing = null }) { Text("Cancel") } },
        )
    }
}

/** the downloads manager */
@Composable
fun DownloadsScreen(onClose: () -> Unit) {
    val ctx = LocalContext.current
    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Column(Modifier.fillMaxSize().background(Color(0xFFF7F6FB)).statusBarsPadding().navigationBarsPadding()) {
            Row(Modifier.fillMaxWidth().padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onClose) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
                Text("Downloads", Modifier.weight(1f), fontSize = 20.sp, fontWeight = FontWeight.SemiBold, color = Ink)
                if (Downloads.list.any { it.done || it.failed }) TextButton(onClick = { Downloads.clearFinished() }) { Text("Clear") }
            }
            if (Downloads.list.isEmpty()) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Text("Nothing downloaded yet", color = Ink.copy(alpha = 0.55f))
                }
            } else {
                LazyColumn(Modifier.fillMaxSize().padding(horizontal = 12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    items(Downloads.list) { d -> DownloadRow(ctx, d) }
                }
            }
        }
    }
}

@Composable
private fun DownloadRow(ctx: Context, d: Download) {
    Column(Modifier.fillMaxWidth().glass(RoundedCornerShape(18.dp)).clickable(enabled = d.done) { Downloads.open(ctx, d) }.padding(14.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.Download, null, tint = if (d.failed) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(d.name, maxLines = 1, overflow = TextOverflow.Ellipsis, fontWeight = FontWeight.Medium, color = Ink)
                Text(
                    when {
                        d.failed -> if (d.cancelled) "Cancelled" else "Failed"
                        d.done -> android.text.format.Formatter.formatShortFileSize(ctx, d.received) + " · Downloads folder"
                        d.total > 0 -> android.text.format.Formatter.formatShortFileSize(ctx, d.received) + " of " + android.text.format.Formatter.formatShortFileSize(ctx, d.total)
                        else -> android.text.format.Formatter.formatShortFileSize(ctx, d.received)
                    },
                    fontSize = 13.sp, color = Ink.copy(alpha = 0.6f),
                )
            }
            IconButton(onClick = { Downloads.remove(ctx, d) }) { Icon(Icons.Filled.Delete, if (d.done) "Delete" else "Cancel") }
        }
        if (!d.done && !d.failed) {
            Spacer(Modifier.height(8.dp))
            if (d.total > 0) LinearProgressIndicator(progress = { d.progress }, Modifier.fillMaxWidth())
            else LinearProgressIndicator(Modifier.fillMaxWidth())
        }
    }
}

/** what a long press on a link, an image or a video offers */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ContextMenuSheet(model: BrowserModel, tab: Tab, el: GeckoSession.ContentDelegate.ContextElement, onClose: () -> Unit) {
    val ctx = LocalContext.current
    fun copy(s: String) {
        (ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(ClipData.newPlainText("link", s))
    }
    fun share(s: String) {
        ctx.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, s), null)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
    fun download(u: String) {
        GeckoWebExecutor(IrisApp.instance.runtime).fetch(WebRequest(u)).accept({ r -> r?.let { Downloads.save(ctx, it, tab.isPrivate) } }, { })
    }
    val link = el.linkUri
    val src = el.srcUri
    ModalBottomSheet(onDismissRequest = onClose, sheetState = rememberModalBottomSheetState(), containerColor = Color(0xFFF8F7FC)) {
        Text(link ?: src ?: el.title ?: "", Modifier.padding(horizontal = 24.dp, vertical = 4.dp), maxLines = 2, overflow = TextOverflow.Ellipsis,
            fontSize = 13.sp, color = Ink.copy(alpha = 0.6f))
        Column(Modifier.verticalScroll(rememberScrollState())) {
            @Composable
            fun item(icon: androidx.compose.ui.graphics.vector.ImageVector, text: String, f: () -> Unit) =
                ListItem(headlineContent = { Text(text) }, leadingContent = { Icon(icon, null) }, colors = clearItem,
                    modifier = Modifier.clickable { onClose(); f() })
            if (link != null) {
                item(Icons.AutoMirrored.Filled.OpenInNew, "Open in new tab") { model.newTab(link, tab.container, after = tab, select = false) }
                Store.containers.filter { it.id != tab.container }.forEach { c ->
                    item(Icons.Filled.Public, "Open in ${c.name}") { model.newTab(link, c.id, after = tab) }
                }
                item(Icons.Filled.ContentCopy, "Copy link") { copy(link) }
                item(Icons.Filled.Share, "Share link") { share(link) }
                item(Icons.Filled.Download, "Download link") { download(link) }
            }
            if (src != null) {
                val image = el.type == GeckoSession.ContentDelegate.ContextElement.TYPE_IMAGE
                item(Icons.Filled.Image, if (image) "Open image in new tab" else "Open video in new tab") { model.newTab(src, tab.container, after = tab) }
                item(Icons.Filled.ContentCopy, if (image) "Copy image address" else "Copy video address") { copy(src) }
                item(Icons.Filled.Download, if (image) "Save image" else "Save video") { download(src) }
            }
            val text = el.textContent
            if (link == null && src == null && !text.isNullOrBlank()) {
                item(Icons.Filled.Search, "Ask Google AI Mode") { model.newTab(Search.aiUrl(text), tab.container, after = tab) }
            }
            Spacer(Modifier.navigationBarsPadding().height(12.dp))
        }
    }
}

/** the new-tab page: colour, the name, and the sites you go to most */
@Composable
fun NewTabPage(model: BrowserModel) {
    val sites = remember(model.current?.id) { Store.topSites(8) }
    Box(
        Modifier.fillMaxSize().background(Brush.linearGradient(listOf(Color(0xFF4B2FB8), Color(0xFF8F4BD9), Color(0xFF2F56D9), Color(0xFF1AA3D9)))),
    ) {
        Column(Modifier.fillMaxSize().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
            Text("Iris", fontSize = 44.sp, fontWeight = FontWeight.ExtraBold, color = Color.White)
            Spacer(Modifier.height(28.dp))
            if (sites.isNotEmpty()) {
                LazyVerticalGrid(GridCells.Fixed(4), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    items(sites) { v ->
                        val name = Search.display(v.url)
                        Column(
                            Modifier.glass(RoundedCornerShape(20.dp), Color.White.copy(alpha = 0.22f)).clickable { model.go(v.url) }.padding(vertical = 12.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                        ) {
                            Box(Modifier.size(40.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.9f)), contentAlignment = Alignment.Center) {
                                Text(name.take(1).uppercase(), fontWeight = FontWeight.Bold, color = IrisViolet, fontSize = 18.sp)
                            }
                            Spacer(Modifier.height(6.dp))
                            Text(name.substringBefore('.').replaceFirstChar { it.uppercase() }, fontSize = 12.sp, color = Color.White,
                                maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(horizontal = 4.dp))
                        }
                    }
                }
            }
        }
    }
}

/** a newer Iris: install it */
@Composable
fun UpdateDialog() {
    val r = Updater.available ?: return
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    AlertDialog(
        onDismissRequest = { if (!Updater.downloading) Updater.available = null },
        title = { Text("Iris ${r.version} is ready") },
        text = {
            if (Updater.downloading) LinearProgressIndicator(progress = { Updater.progress }, Modifier.fillMaxWidth())
            else Text("Iris downloads it from GitHub and Android installs it over this version. Your tabs stay.")
        },
        confirmButton = {
            TextButton(enabled = !Updater.downloading, onClick = { scope.launch { Updater.install(ctx, r) } }) { Text("Update") }
        },
        dismissButton = { TextButton(enabled = !Updater.downloading, onClick = { Updater.available = null }) { Text("Later") } },
    )
}
