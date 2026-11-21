@file:OptIn(ExperimentalFoundationApi::class)

package org.tulipanlabs.iris.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

// Iris's own pieces, in Liquid Glass: no Material components anywhere.

@Composable
fun Txt(
    text: String, modifier: Modifier = Modifier, size: TextUnit = 15.sp, weight: FontWeight = FontWeight.Normal,
    color: Color = LocalPalette.current.ink, maxLines: Int = Int.MAX_VALUE,
) {
    BasicText(text, modifier, style = TextStyle(fontSize = size, fontWeight = weight, color = color), maxLines = maxLines, overflow = TextOverflow.Ellipsis)
}

@Composable
fun GlyphIcon(g: Glyph, modifier: Modifier = Modifier, size: Dp = 22.dp, tint: Color = LocalPalette.current.ink) {
    Image(rememberVectorPainter(Glyphs.vector(g)), null, modifier.size(size), colorFilter = ColorFilter.tint(tint))
}

/** a press gives a little, as glass under a finger */
@Composable
private fun pressScale(source: MutableInteractionSource): Float {
    val pressed by source.collectIsPressedAsState()
    val k by animateFloatAsState(if (pressed) 0.92f else 1f, spring(dampingRatio = 0.55f, stiffness = Spring.StiffnessMedium), label = "press")
    return k
}

/** a round button of glass with a glyph */
@Composable
fun GlassButton(
    g: Glyph, desc: String, onClick: () -> Unit, modifier: Modifier = Modifier, size: Dp = 44.dp, enabled: Boolean = true,
    clear: Boolean = false, tint: Color? = null, onLong: (() -> Unit)? = null,
) {
    val p = LocalPalette.current
    val src = remember { MutableInteractionSource() }
    Box(
        modifier.size(size).scale(pressScale(src))
            .then(if (clear) Modifier.clip(CircleShape) else Modifier.glass(p, CircleShape))
            .combinedClickable(interactionSource = src, indication = null, enabled = enabled, onClick = onClick, onLongClick = onLong)
            .semantics { contentDescription = desc },
        contentAlignment = Alignment.Center,
    ) { GlyphIcon(g, size = size * 0.5f, tint = (tint ?: p.ink).copy(alpha = if (enabled) 1f else 0.3f)) }
}

/** a capsule of glass with words */
@Composable
fun GlassPill(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, strong: Boolean = false) {
    val p = LocalPalette.current
    val src = remember { MutableInteractionSource() }
    Box(
        modifier.scale(pressScale(src))
            .then(if (strong) Modifier.clip(RoundedCornerShape(50)).background(p.accent) else Modifier.glass(p))
            .combinedClickable(interactionSource = src, indication = null, onClick = onClick)
            .padding(horizontal = 18.dp, vertical = 10.dp),
        contentAlignment = Alignment.Center,
    ) { Txt(text, weight = FontWeight.SemiBold, color = if (strong) Color.White else p.ink) }
}

/** a row of a panel: a glyph, words, and something at the end */
@Composable
fun GlassRow(
    g: Glyph?, title: String, onClick: (() -> Unit)? = null, sub: String? = null, tint: Color? = null,
    end: (@Composable () -> Unit)? = null,
) {
    val p = LocalPalette.current
    val src = remember { MutableInteractionSource() }
    val pressed by src.collectIsPressedAsState()
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 8.dp).clip(RoundedCornerShape(16.dp))
            .background(if (pressed) p.hover else Color.Transparent)
            .then(if (onClick != null) Modifier.combinedClickable(interactionSource = src, indication = null, onClick = onClick) else Modifier)
            .padding(horizontal = 14.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (g != null) {
            GlyphIcon(g, size = 22.dp, tint = tint ?: p.ink)
            Spacer(Modifier.width(14.dp))
        }
        Column(Modifier.weight(1f)) {
            Txt(title, size = 16.sp, weight = FontWeight.Medium, maxLines = 1)
            if (sub != null) Txt(sub, size = 13.sp, color = p.ink2)
        }
        end?.invoke()
    }
}

/** an on-off switch, as on an iPhone */
@Composable
fun GlassToggle(on: Boolean, onChange: (Boolean) -> Unit) {
    val p = LocalPalette.current
    val x by animateDpAsState(if (on) 22.dp else 2.dp, spring(dampingRatio = 0.6f, stiffness = Spring.StiffnessMediumLow), label = "knob")
    val track by animateColorAsState(if (on) p.green else p.ink.copy(alpha = 0.16f), label = "track")
    val src = remember { MutableInteractionSource() }
    Box(
        Modifier.size(51.dp, 31.dp).clip(RoundedCornerShape(50)).background(track)
            .combinedClickable(interactionSource = src, indication = null) { onChange(!on) },
    ) {
        Box(Modifier.offset(x = x, y = 2.dp).size(27.dp).shadow(3.dp, CircleShape).clip(CircleShape).background(Color.White))
    }
}

/** choices in one capsule; the chosen one sits on a drop of glass that slides */
@Composable
fun Segmented(options: List<Pair<Glyph?, String>>, selected: Int, onSelect: (Int) -> Unit, modifier: Modifier = Modifier) {
    val p = LocalPalette.current
    BoxWithConstraints(modifier.fillMaxWidth().height(44.dp).glass(p)) {
        val w = maxWidth / options.size
        val x by animateDpAsState(w * selected, spring(dampingRatio = 0.72f, stiffness = Spring.StiffnessMediumLow), label = "thumb")
        Box(Modifier.offset(x = x).padding(4.dp).width(w - 8.dp).height(36.dp)
            .glass(p, RoundedCornerShape(50), tint = if (p.dark) Color.White.copy(alpha = 0.16f) else Color.White.copy(alpha = 0.95f), elevation = 2.dp))
        Row(Modifier.fillMaxSize()) {
            options.forEachIndexed { i, (g, name) ->
                val src = remember { MutableInteractionSource() }
                Row(
                    Modifier.weight(1f).fillMaxSize().combinedClickable(interactionSource = src, indication = null) { onSelect(i) },
                    horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically,
                ) {
                    if (g != null) { GlyphIcon(g, size = 16.dp); Spacer(Modifier.width(6.dp)) }
                    Txt(name, size = 14.sp, weight = if (i == selected) FontWeight.SemiBold else FontWeight.Medium, maxLines = 1)
                }
            }
        }
    }
}

/** a thin line of how far something has come */
@Composable
fun ProgressLine(fraction: Float?, modifier: Modifier = Modifier) {
    val p = LocalPalette.current
    Box(modifier.fillMaxWidth().height(4.dp).clip(RoundedCornerShape(50)).background(p.ink.copy(alpha = 0.10f))) {
        Box(Modifier.fillMaxWidth(fraction ?: 0.35f).height(4.dp).clip(RoundedCornerShape(50)).background(p.accent))
    }
}

@Composable
fun Separator() {
    Box(Modifier.fillMaxWidth().padding(horizontal = 22.dp, vertical = 6.dp).height(1.dp).background(LocalPalette.current.ink.copy(alpha = 0.10f)))
}

@Composable
fun SectionTitle(text: String) {
    Txt(text.uppercase(), Modifier.padding(start = 24.dp, end = 24.dp, top = 10.dp, bottom = 4.dp), size = 12.sp, weight = FontWeight.Bold, color = LocalPalette.current.ink2)
}

/** a panel that rises from the bottom over a dimmed page; a tap above it closes it */
@Composable
fun GlassSheet(open: Boolean, onDismiss: () -> Unit, title: String? = null, content: @Composable ColumnScope.() -> Unit) {
    val p = LocalPalette.current
    AnimatedVisibility(open, enter = fadeIn(), exit = fadeOut()) {
        Box(Modifier.fillMaxSize().background(p.scrim).combinedClickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = onDismiss))
    }
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.BottomCenter) {
        AnimatedVisibility(open, enter = slideInVertically(spring(dampingRatio = 0.82f, stiffness = Spring.StiffnessMediumLow)) { it } + fadeIn(),
            exit = slideOutVertically { it } + fadeOut()) {
            Column(
                Modifier.widthIn(max = 640.dp).fillMaxWidth().padding(8.dp)
                    .glass(p, RoundedCornerShape(30.dp), tint = p.panel, elevation = 18.dp)
                    .combinedClickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {}
                    .navigationBarsPadding().padding(top = 8.dp, bottom = 12.dp),
            ) {
                Box(Modifier.align(Alignment.CenterHorizontally).size(38.dp, 5.dp).clip(RoundedCornerShape(50)).background(p.ink.copy(alpha = 0.2f)))
                if (title != null) Txt(title, Modifier.padding(start = 24.dp, end = 24.dp, top = 12.dp, bottom = 6.dp), size = 22.sp, weight = FontWeight.Bold)
                Column(Modifier.verticalScroll(rememberScrollState()), content = content)
            }
        }
    }
}

/** a question in a card of glass, in the middle */
@Composable
fun GlassDialog(open: Boolean, title: String, onDismiss: () -> Unit, confirm: String, onConfirm: () -> Unit, danger: Boolean = false,
                cancel: String = "Cancel", content: @Composable ColumnScope.() -> Unit = {}) {
    val p = LocalPalette.current
    AnimatedVisibility(open, enter = fadeIn(), exit = fadeOut()) {
        Box(Modifier.fillMaxSize().background(p.scrim).combinedClickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = onDismiss),
            contentAlignment = Alignment.Center) {
            AnimatedVisibility(open, enter = scaleIn(initialScale = 0.9f) + fadeIn(), exit = scaleOut(targetScale = 0.95f) + fadeOut()) {
                Column(
                    Modifier.widthIn(max = 360.dp).padding(24.dp).glass(p, RoundedCornerShape(28.dp), tint = p.panel, elevation = 20.dp)
                        .combinedClickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {}
                        .padding(20.dp),
                ) {
                    Txt(title, size = 19.sp, weight = FontWeight.Bold)
                    Spacer(Modifier.height(10.dp))
                    content()
                    Spacer(Modifier.height(18.dp))
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        GlassPill(cancel, onDismiss, Modifier.weight(1f))
                        val src = remember { MutableInteractionSource() }
                        Box(
                            Modifier.weight(1f).clip(RoundedCornerShape(50)).background(if (danger) p.danger else p.accent)
                                .combinedClickable(interactionSource = src, indication = null, onClick = onConfirm).padding(vertical = 10.dp),
                            contentAlignment = Alignment.Center,
                        ) { Txt(confirm, weight = FontWeight.SemiBold, color = Color.White) }
                    }
                }
            }
        }
    }
}
