@file:OptIn(ExperimentalFoundationApi::class)

package org.tulipanlabs.iris.ui

import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import kotlinx.coroutines.delay
import org.tulipanlabs.iris.BrowserModel
import org.tulipanlabs.iris.R
import org.tulipanlabs.iris.Search
import org.tulipanlabs.iris.Store
import org.tulipanlabs.iris.Tab

enum class Sheet { NONE, MENU, SHIELDS, CONTAINERS, DOWNLOADS }

@Composable
fun BrowserScreen(model: BrowserModel) {
    val p = LocalPalette.current
    var sheet by remember { mutableStateOf(Sheet.NONE) }
    var note by remember { mutableStateOf<String?>(null) }

    // a pop-up Iris stopped: a note that offers it
    LaunchedEffect(model.blocked) {
        val b = model.blocked ?: return@LaunchedEffect
        note = "Pop-up stopped"
        delay(4000)
        if (model.blocked === b) model.blocked = null
        note = null
    }

    Box(Modifier.fillMaxSize().background(Brush.verticalGradient(p.back))) {
        Column(Modifier.fillMaxSize().imePadding()) {
            AnimatedVisibility(!model.fullscreen, enter = slideInVertically() + fadeIn(), exit = slideOutVertically() + fadeOut()) {
                Column(Modifier.statusBarsPadding()) {
                    TabStrip(model, onContainers = { sheet = Sheet.CONTAINERS })
                    AddressRow(model)
                }
            }
            Box(Modifier.weight(1f).fillMaxWidth()) { PageArea(model) }
            AnimatedVisibility(!model.fullscreen, enter = slideInVertically { it } + fadeIn(), exit = slideOutVertically { it } + fadeOut()) {
                BottomBar(model, onSheet = { sheet = it })
            }
        }
        // a short note above the bar
        AnimatedVisibility(note != null, Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(bottom = 84.dp),
            enter = fadeIn() + slideInVertically { it / 2 }, exit = fadeOut()) {
            Row(Modifier.glass(p, RoundedCornerShape(50), tint = p.panel, elevation = 8.dp).padding(start = 18.dp, end = 6.dp, top = 6.dp, bottom = 6.dp),
                verticalAlignment = Alignment.CenterVertically) {
                Txt(note ?: "", weight = FontWeight.Medium)
                Spacer(Modifier.width(10.dp))
                model.blocked?.let { b -> GlassPill("Open", { model.newTab(b.url, b.from.container, after = b.from); model.blocked = null; note = null }, strong = true) }
            }
        }
        MenuSheet(model, sheet == Sheet.MENU, onSheet = { sheet = it })
        ShieldsSheet(model, sheet == Sheet.SHIELDS) { sheet = Sheet.NONE }
        ContainersSheet(model, sheet == Sheet.CONTAINERS) { sheet = Sheet.NONE }
        DownloadsSheet(sheet == Sheet.DOWNLOADS) { sheet = Sheet.NONE }
        ContextSheet(model, model.pressed) { model.pressed = null }
        UpdateDialog()
    }
}

/** the tabs, as on a computer: pills in a row, the selected one in glass */
@Composable
private fun TabStrip(model: BrowserModel, onContainers: () -> Unit) {
    val state = rememberLazyListState()
    val sel = model.tabs.indexOf(model.current)
    LaunchedEffect(sel, model.tabs.size) { if (sel >= 0) state.animateScrollToItem(sel) }
    Row(Modifier.fillMaxWidth().padding(start = 8.dp, end = 6.dp, top = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        LazyRow(Modifier.weight(1f), state = state, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            itemsIndexed(model.tabs, key = { _, t -> t.id }) { _, t ->
                TabPill(t, selected = t === model.current, onSelect = { model.select(t) }, onClose = { model.close(t) }, modifier = Modifier.animateItem())
            }
        }
        // a tap opens a tab, a long press picks its container
        GlassButton(Glyph.PLUS, "New tab", { model.newTab() }, Modifier.padding(start = 6.dp), size = 38.dp, onLong = onContainers)
    }
}

@Composable
private fun TabPill(t: Tab, selected: Boolean, onSelect: () -> Unit, onClose: () -> Unit, modifier: Modifier) {
    val p = LocalPalette.current
    val c = Store.container(t.container)
    val width by animateDpAsState(if (selected) 176.dp else 128.dp, spring(dampingRatio = 0.75f, stiffness = Spring.StiffnessMediumLow), label = "tab")
    val shape = RoundedCornerShape(19.dp)
    val tint by animateColorAsState(c?.let { Color(it.color).copy(alpha = 0.26f) } ?: p.glass, label = "tint")
    Row(
        modifier.height(38.dp).width(width)
            .then(if (selected) Modifier.glass(p, shape, tint = tint) else Modifier.clip(shape).background(p.ink.copy(alpha = if (p.dark) 0.06f else 0.04f)))
            .combinedClickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = onSelect)
            .padding(start = 12.dp, end = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (c != null) {
            GlyphIcon(Glyphs.container(c.icon), size = 15.dp, tint = Color(c.color))
            Spacer(Modifier.width(6.dp))
        }
        Txt(t.title.ifEmpty { Search.display(t.url).ifEmpty { "New Tab" } }, Modifier.weight(1f), size = 13.sp,
            weight = if (selected) FontWeight.SemiBold else FontWeight.Medium, color = if (selected) p.ink else p.ink2, maxLines = 1)
        if (selected) GlassButton(Glyph.CLOSE, "Close tab", onClose, size = 30.dp, clear = true)
    }
}

/** the address: the site's name, or your question; tap to type */
@Composable
private fun AddressRow(model: BrowserModel) {
    val p = LocalPalette.current
    val t = model.current
    val focus = LocalFocusManager.current
    var editing by remember { mutableStateOf(false) }
    var value by remember { mutableStateOf(TextFieldValue("")) }
    val requester = remember { FocusRequester() }
    LaunchedEffect(t?.url, editing) { if (!editing) value = TextFieldValue(Search.display(t?.url ?: "")) }
    LaunchedEffect(t?.id) { if (t != null && t.url.isEmpty() && t.pending == null) runCatching { requester.requestFocus() } }
    Box(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 6.dp)) {
        Row(Modifier.fillMaxWidth().height(48.dp).glass(p, RoundedCornerShape(24.dp)), verticalAlignment = Alignment.CenterVertically) {
            Spacer(Modifier.width(16.dp))
            val c = Store.container(t?.container)
            when {
                c != null && !editing -> {
                    Row(Modifier.clip(RoundedCornerShape(10.dp)).background(Color(c.color)).padding(horizontal = 8.dp, vertical = 2.dp),
                        verticalAlignment = Alignment.CenterVertically) {
                        GlyphIcon(Glyphs.container(c.icon), size = 13.dp, tint = Color.White)
                        Spacer(Modifier.width(4.dp))
                        Txt(c.name, size = 12.sp, weight = FontWeight.SemiBold, color = Color.White)
                    }
                    Spacer(Modifier.width(8.dp))
                }
                !editing && (t?.url ?: "").startsWith("https://") -> {
                    GlyphIcon(Glyph.LOCK, size = 15.dp, tint = p.ink2)
                    Spacer(Modifier.width(6.dp))
                }
                editing -> {
                    GlyphIcon(Glyph.SEARCH, size = 17.dp, tint = p.ink2)
                    Spacer(Modifier.width(8.dp))
                }
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
                textStyle = TextStyle(fontSize = 16.sp, color = p.ink, fontWeight = if (editing) FontWeight.Normal else FontWeight.Medium),
                cursorBrush = SolidColor(p.accent),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Go, autoCorrectEnabled = false),
                keyboardActions = KeyboardActions(onGo = { model.go(value.text); focus.clearFocus() }),
                decorationBox = { inner ->
                    Box {
                        if (value.text.isEmpty()) Txt("Ask anything, or type an address", color = p.ink2, maxLines = 1)
                        inner()
                    }
                },
            )
            if (editing && value.text.isNotEmpty()) {
                GlassButton(Glyph.CLOSE, "Clear", { value = TextFieldValue("") }, size = 40.dp, clear = true)
            } else if (t != null && t.url.isNotEmpty()) {
                GlassButton(if (t.loading) Glyph.CLOSE else Glyph.RELOAD, if (t.loading) "Stop" else "Reload",
                    { if (t.loading) t.stop() else t.reload() }, size = 40.dp, clear = true)
            }
            Spacer(Modifier.width(4.dp))
        }
        // how far the page has loaded, along the bottom of the capsule
        val prog by animateFloatAsState((t?.progress ?: 0) / 100f, label = "progress")
        AnimatedVisibility(t?.loading == true, Modifier.align(Alignment.BottomCenter).padding(horizontal = 26.dp), enter = fadeIn(), exit = fadeOut()) {
            Box(Modifier.fillMaxWidth().height(2.dp)) {
                Box(Modifier.fillMaxWidth(prog.coerceIn(0.02f, 1f)).height(2.dp).clip(RoundedCornerShape(50)).background(p.accent))
            }
        }
    }
}

/** the page itself (Chromium's surface), or the new-tab page */
@Composable
private fun PageArea(model: BrowserModel) {
    val t = model.current
    Box(Modifier.fillMaxSize().padding(horizontal = 6.dp).clip(RoundedCornerShape(20.dp))) {
        val w = t?.web
        if (w == null) {
            NewTabPage(model)
        } else {
            AndroidView(
                factory = { ctx -> FrameLayout(ctx) },
                // the shown tab's page, moved into the frame
                update = { frame ->
                    if (w.parent !== frame) {
                        (w.parent as? ViewGroup)?.removeView(w)
                        frame.removeAllViews()
                        frame.addView(w, ViewGroup.LayoutParams(-1, -1))
                    }
                },
                modifier = Modifier.fillMaxSize(),
            )
        }
    }
}

/** back, forward, home, Shields, tabs and the menu, on one capsule of glass */
@Composable
private fun BottomBar(model: BrowserModel, onSheet: (Sheet) -> Unit) {
    val p = LocalPalette.current
    val t = model.current
    Row(
        Modifier.navigationBarsPadding().fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp)
            .height(58.dp).glass(p, RoundedCornerShape(29.dp), elevation = 6.dp),
        horizontalArrangement = Arrangement.SpaceEvenly, verticalAlignment = Alignment.CenterVertically,
    ) {
        GlassButton(Glyph.BACK, "Back", { t?.back() }, enabled = t?.canBack == true, clear = true)
        GlassButton(Glyph.FORWARD, "Forward", { t?.forward() }, enabled = t?.canForward == true, clear = true)
        GlassButton(Glyph.HOME, "Home", { t?.let { model.home(it) } }, clear = true)
        val on = t?.let { model.shieldsFor(it.url) } ?: Store.shields
        Box {
            GlassButton(if (on) Glyph.SHIELD_ON else Glyph.SHIELD, "Shields", { onSheet(Sheet.SHIELDS) }, clear = true, tint = if (on) p.accent else p.ink2)
            val n = t?.blocked ?: 0
            if (on && n > 0) {
                Box(Modifier.align(Alignment.TopEnd).padding(top = 2.dp).clip(RoundedCornerShape(50)).background(p.accent).padding(horizontal = 5.dp, vertical = 1.dp)) {
                    Txt(if (n > 99) "99+" else "$n", size = 10.sp, weight = FontWeight.Bold, color = Color.White)
                }
            }
        }
        GlassButton(Glyph.LAYERS, "Containers", { onSheet(Sheet.CONTAINERS) }, clear = true)
        GlassButton(Glyph.MORE, "Menu", { onSheet(Sheet.MENU) }, clear = true)
    }
}

/** the new-tab page: Iris (Ember's wallpaper, light by day and dark by
 *  night), the name, and the sites you go to most */
@Composable
fun NewTabPage(model: BrowserModel) {
    val p = LocalPalette.current
    val sites = remember(model.current?.id) { Store.topSites(8) }
    Box(Modifier.fillMaxSize()) {
        Image(painterResource(if (p.dark) R.drawable.iris_dark else R.drawable.iris_light), null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
        Column(Modifier.fillMaxSize().padding(horizontal = 22.dp, vertical = 36.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Spacer(Modifier.height(24.dp))
            Txt("Iris", size = 46.sp, weight = FontWeight.ExtraBold)
            Spacer(Modifier.height(22.dp))
            if (sites.isNotEmpty()) {
                Row(Modifier.widthIn(max = 520.dp).fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    sites.take(4).forEach { v -> SiteTile(Search.display(v.url), Modifier.weight(1f)) { model.go(v.url) } }
                }
                if (sites.size > 4) {
                    Spacer(Modifier.height(10.dp))
                    Row(Modifier.widthIn(max = 520.dp).fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        sites.drop(4).take(4).forEach { v -> SiteTile(Search.display(v.url), Modifier.weight(1f)) { model.go(v.url) } }
                        repeat(4 - sites.drop(4).take(4).size) { Spacer(Modifier.weight(1f)) }
                    }
                }
            }
        }
    }
}

@Composable
private fun SiteTile(name: String, modifier: Modifier, onClick: () -> Unit) {
    val p = LocalPalette.current
    Column(
        modifier.glass(p, RoundedCornerShape(22.dp)).combinedClickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = onClick)
            .padding(vertical = 12.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(Modifier.size(40.dp).clip(CircleShape).background(p.accent.copy(alpha = 0.16f)), contentAlignment = Alignment.Center) {
            Txt(name.take(1).uppercase(), size = 18.sp, weight = FontWeight.Bold, color = p.accent)
        }
        Spacer(Modifier.height(6.dp))
        Txt(name.substringBefore('.').replaceFirstChar { it.uppercase() }, Modifier.padding(horizontal = 4.dp), size = 12.sp, maxLines = 1)
    }
}
