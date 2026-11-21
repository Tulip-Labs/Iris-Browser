package org.tulipanlabs.iris.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Layers
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.outlined.Shield
import androidx.compose.material3.Badge
import androidx.compose.material3.BadgedBox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.swiperefreshlayout.widget.SwipeRefreshLayout
import kotlinx.coroutines.launch
import org.tulipanlabs.iris.BrowserModel
import org.tulipanlabs.iris.Container
import org.tulipanlabs.iris.Downloads
import org.tulipanlabs.iris.Search
import org.tulipanlabs.iris.Store
import org.tulipanlabs.iris.Tab

enum class Sheet { NONE, SHIELDS, CONTAINERS, DOWNLOADS }

@Composable
fun BrowserScreen(model: BrowserModel) {
    var sheet by remember { mutableStateOf(Sheet.NONE) }
    val snack = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()

    // a pop-up Iris stopped: say so, and offer it
    LaunchedEffect(model.blocked) {
        val b = model.blocked ?: return@LaunchedEffect
        model.blocked = null
        val r = snack.showSnackbar("Pop-up blocked", actionLabel = "Open", duration = SnackbarDuration.Short)
        if (r == SnackbarResult.ActionPerformed) model.newTab(b.url, b.from.container, after = b.from)
    }

    Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color(0xFFEDE8FF), Color(0xFFF4F7FF), Color(0xFFF7F6FB))))) {
        Column(Modifier.fillMaxSize().imePadding()) {
            AnimatedVisibility(model.fullscreen == null, enter = slideInVertically() + fadeIn(), exit = slideOutVertically() + fadeOut()) {
                Column(Modifier.statusBarsPadding()) {
                    TabStrip(model, onContainers = { sheet = Sheet.CONTAINERS })
                    AddressRow(model)
                }
            }
            Box(Modifier.weight(1f).fillMaxWidth()) {
                Page(model)
                SnackbarHost(snack, Modifier.align(Alignment.BottomCenter).padding(12.dp))
            }
            AnimatedVisibility(model.fullscreen == null, enter = slideInVertically { it } + fadeIn(), exit = slideOutVertically { it } + fadeOut()) {
                BottomBar(model, onShields = { sheet = Sheet.SHIELDS }, onDownloads = { sheet = Sheet.DOWNLOADS }, onContainers = { sheet = Sheet.CONTAINERS })
            }
        }
    }

    when (sheet) {
        Sheet.SHIELDS -> ShieldsSheet(model) { sheet = Sheet.NONE }
        Sheet.CONTAINERS -> ContainersSheet(model) { sheet = Sheet.NONE }
        Sheet.DOWNLOADS -> DownloadsScreen { sheet = Sheet.NONE }
        Sheet.NONE -> {}
    }
    model.pressed?.let { p -> ContextMenuSheet(model, p) { model.pressed = null } }
    // a video in full screen, over everything
    model.fullscreen?.let { v ->
        AndroidView(factory = { ctx -> android.widget.FrameLayout(ctx).apply { setBackgroundColor(android.graphics.Color.BLACK) } },
            update = { f -> if (v.parent !== f) { (v.parent as? android.view.ViewGroup)?.removeView(v); f.removeAllViews(); f.addView(v) } },
            modifier = Modifier.fillMaxSize())
    }
    UpdateDialog()
}

/** the tabs, as on a computer: pills in a row, the selected one in glass */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun TabStrip(model: BrowserModel, onContainers: () -> Unit) {
    val state = rememberLazyListState()
    val sel = model.tabs.indexOf(model.current)
    LaunchedEffect(sel, model.tabs.size) { if (sel >= 0) state.animateScrollToItem(sel) }
    Row(Modifier.fillMaxWidth().padding(start = 8.dp, end = 4.dp, top = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        LazyRow(Modifier.weight(1f), state = state, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            itemsIndexed(model.tabs, key = { _, t -> t.id }) { _, t ->
                TabPill(t, selected = t === model.current, onSelect = { model.select(t) }, onClose = { model.close(t) },
                    modifier = Modifier.animateItem())
            }
        }
        // the one "+": a tap opens a tab, a long press picks its container
        Box(
            Modifier.padding(start = 6.dp).size(36.dp).glass(CircleShape)
                .combinedClickable(onClick = { model.newTab() }, onLongClick = onContainers),
            contentAlignment = Alignment.Center,
        ) { Icon(Icons.Filled.Add, "New tab", tint = Ink) }
    }
}

@Composable
private fun TabPill(t: Tab, selected: Boolean, onSelect: () -> Unit, onClose: () -> Unit, modifier: Modifier) {
    val c = Store.container(t.container)
    val tint by animateColorAsState(
        if (selected) (c?.let { Color(it.color).copy(alpha = 0.22f) } ?: Color.White.copy(alpha = 0.92f)) else Color.White.copy(alpha = 0.0f),
        spring(stiffness = Spring.StiffnessMediumLow), label = "tab",
    )
    val shape = RoundedCornerShape(18.dp)
    Row(
        modifier.height(36.dp).width(if (selected) 176.dp else 132.dp)
            .then(if (selected) Modifier.glass(shape, tint) else Modifier.clip(shape).background(Color.White.copy(alpha = 0.35f)))
            .clickable(onClick = onSelect)
            .padding(start = 12.dp, end = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (c != null) Icon(containerIcon(c.icon), c.name, Modifier.size(15.dp), tint = Color(c.color))
        if (c != null) Spacer(Modifier.width(6.dp))
        Text(
            t.title.ifEmpty { Search.display(t.url).ifEmpty { "New Tab" } },
            Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis,
            fontSize = 13.sp, fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium, color = Ink,
        )
        if (selected) IconButton(onClick = onClose, Modifier.size(28.dp)) { Icon(Icons.Filled.Close, "Close tab", Modifier.size(16.dp), tint = Ink) }
    }
}


/** the address: the site's name, or your question; tap to type */
@Composable
private fun AddressRow(model: BrowserModel) {
    val t = model.current
    val focus = LocalFocusManager.current
    var editing by remember { mutableStateOf(false) }
    var value by remember { mutableStateOf(TextFieldValue("")) }
    val requester = remember { FocusRequester() }
    LaunchedEffect(t?.url, editing) {
        if (!editing) value = TextFieldValue(Search.display(t?.url ?: ""))
    }
    // a new, empty tab is ready for typing
    LaunchedEffect(t?.id) { if (t != null && t.url.isEmpty() && t.pending == null) runCatching { requester.requestFocus() } }
    Box(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 6.dp)) {
        Row(
            Modifier.fillMaxWidth().height(46.dp).glass(RoundedCornerShape(23.dp), Color.White.copy(alpha = if (editing) 0.95f else 0.75f)),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Spacer(Modifier.width(16.dp))
            val c = Store.container(t?.container)
            if (c != null && !editing) {
                Row(Modifier.clip(RoundedCornerShape(10.dp)).background(Color(c.color)).padding(horizontal = 8.dp, vertical = 2.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Icon(containerIcon(c.icon), null, Modifier.size(13.dp), tint = Color.White)
                    Spacer(Modifier.width(4.dp))
                    Text(c.name, color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                }
                Spacer(Modifier.width(8.dp))
            } else if (!editing && (t?.url ?: "").startsWith("https://")) {
                Icon(Icons.Filled.Lock, "Secure", Modifier.size(14.dp), tint = Ink.copy(alpha = 0.5f))
                Spacer(Modifier.width(6.dp))
            }
            BasicTextField(
                value = value,
                onValueChange = { value = it },
                modifier = Modifier.weight(1f).focusRequester(requester).onFocusChanged { f ->
                    if (f.isFocused && !editing) {
                        editing = true
                        val e = Search.editable(t?.url ?: "")
                        value = TextFieldValue(e, TextRange(0, e.length))
                    } else if (!f.isFocused) editing = false
                },
                singleLine = true,
                textStyle = TextStyle(fontSize = 16.sp, color = Ink, fontWeight = if (editing) FontWeight.Normal else FontWeight.Medium),
                cursorBrush = SolidColor(MaterialTheme.colorScheme.secondary),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Go, autoCorrectEnabled = false),
                keyboardActions = KeyboardActions(onGo = { model.go(value.text); focus.clearFocus() }),
            )
            if (editing && value.text.isNotEmpty()) {
                IconButton(onClick = { value = TextFieldValue("") }) { Icon(Icons.Filled.Close, "Clear", tint = Ink) }
            } else if (t != null && t.url.isNotEmpty()) {
                IconButton(onClick = { if (t.loading) t.stop() else t.reload() }) {
                    Icon(if (t.loading) Icons.Filled.Close else Icons.Filled.Refresh, if (t.loading) "Stop" else "Reload", tint = Ink)
                }
            }
        }
        // how far the page has loaded, along the bottom of the capsule
        val p by animateFloatAsState((t?.progress ?: 0) / 100f, label = "progress")
        AnimatedVisibility(t?.loading == true, Modifier.align(Alignment.BottomCenter), enter = fadeIn(), exit = fadeOut()) {
            LinearProgressIndicator(progress = { p }, Modifier.fillMaxWidth().padding(horizontal = 22.dp).height(2.dp),
                color = MaterialTheme.colorScheme.secondary, trackColor = Color.Transparent)
        }
    }
}

/** the page itself, or the new-tab page; pull down at the top to reload */
@Composable
private fun Page(model: BrowserModel) {
    val t = model.current
    Box(Modifier.fillMaxSize().padding(horizontal = 6.dp).clip(RoundedCornerShape(18.dp))) {
        val w = t?.web
        if (w == null) {
            NewTabPage(model)
        } else {
            AndroidView(
                factory = { ctx ->
                    SwipeRefreshLayout(ctx).apply {
                        setColorSchemeColors(0xFF5B3CC4.toInt())
                        setOnRefreshListener {
                            model.current?.reload()
                            postDelayed({ isRefreshing = false }, 900)
                        }
                    }
                },
                // the shown tab's WebView, moved into the pull-to-reload frame
                update = { frame ->
                    if (w.parent !== frame) {
                        (w.parent as? android.view.ViewGroup)?.removeView(w)
                        frame.removeAllViews()
                        frame.addView(w, android.view.ViewGroup.LayoutParams(-1, -1))
                    }
                },
                modifier = Modifier.fillMaxSize(),
            )
        }
    }
}

/** back, forward, home, shields, containers and downloads */
@Composable
private fun BottomBar(model: BrowserModel, onShields: () -> Unit, onDownloads: () -> Unit, onContainers: () -> Unit) {
    val t = model.current
    Row(
        Modifier.navigationBarsPadding().fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp)
            .height(52.dp).glass(RoundedCornerShape(26.dp)),
        horizontalArrangement = Arrangement.SpaceEvenly, verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(onClick = { t?.back() }, enabled = t?.canBack == true) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
        IconButton(onClick = { t?.forward() }, enabled = t?.canForward == true) { Icon(Icons.AutoMirrored.Filled.ArrowForward, "Forward") }
        IconButton(onClick = { t?.let { model.home(it) } }) { Icon(Icons.Filled.Home, "Home") }
        val on = t?.let { model.shieldsFor(it.url) } ?: Store.shields
        IconButton(onClick = onShields) { Icon(if (on) Icons.Filled.Shield else Icons.Outlined.Shield, "Shields", tint = if (on) MaterialTheme.colorScheme.primary else Ink) }
        IconButton(onClick = onContainers) { Icon(Icons.Filled.Layers, "Containers") }
        IconButton(onClick = onDownloads) {
            BadgedBox(badge = { if (Downloads.active > 0) Badge { Text("${Downloads.active}") } }) { Icon(Icons.Filled.Download, "Downloads") }
        }
    }
}
