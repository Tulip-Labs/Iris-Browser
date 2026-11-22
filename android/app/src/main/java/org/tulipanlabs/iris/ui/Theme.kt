package org.tulipanlabs.iris.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import org.tulipanlabs.iris.Store

/** Light, Dark, or Auto (the phone's choice), as in Ember and on Linux */
object Look {
    var appearance by mutableStateOf(Store.appearance)
        private set

    fun set(a: String) {
        appearance = a
        Store.appearance = a
    }

    /** Iris is light (Dark and Auto were choices before 2.1.1) */
    @Suppress("UNUSED_PARAMETER")
    fun isDark(system: Boolean) = false
}

/** the colours of one look: Iris's day (pearl, pink and sky) or night (indigo) */
class Palette(val dark: Boolean) {
    val ink = if (dark) Color(0xFFF5F5F7) else Color(0xFF241C40)
    val ink2 = ink.copy(alpha = 0.62f)
    val accent = if (dark) Color(0xFF64B5FF) else Color(0xFF6A4CF5)
    val green = Color(0xFF34C759)
    val danger = Color(0xFFFF453A)
    /** behind everything: the window's own wash */
    val back = if (dark) listOf(Color(0xFF0B0920), Color(0xFF17134A), Color(0xFF0A2440))
        else listOf(Color(0xFFDCE0FF), Color(0xFFEDE3FF), Color(0xFFFFE3F0), Color(0xFFFFEEE2))
    /** the glass of bars and buttons, and of panels (more solid, for reading) */
    val glass = if (dark) Color(0xFF26233A).copy(alpha = 0.62f) else Color.White.copy(alpha = 0.66f)
    val panel = if (dark) Color(0xFF1C1A2C).copy(alpha = 0.92f) else Color(0xFFFBFBFE).copy(alpha = 0.92f)
    val hover = ink.copy(alpha = if (dark) 0.10f else 0.06f)
    val rimTop = Color.White.copy(alpha = if (dark) 0.45f else 0.95f)
    val rimMid = Color.White.copy(alpha = if (dark) 0.08f else 0.25f)
    val rimEdge = Color.Black.copy(alpha = if (dark) 0.25f else 0.06f)
    val sheen = Color.White.copy(alpha = if (dark) 0.10f else 0.50f)
    val scrim = Color.Black.copy(alpha = if (dark) 0.45f else 0.22f)
}

val LocalPalette = staticCompositionLocalOf { Palette(false) }

@Composable
fun IrisTheme(dark: Boolean, content: @Composable () -> Unit) {
    CompositionLocalProvider(LocalPalette provides Palette(dark), content = content)
}

/**
 * Liquid Glass: a tint of the look, light falling from above (a sheen at
 * the top, a soft shade at the bottom), and a rim of light round the edge,
 * bright where the light comes from and again opposite.
 */
fun Modifier.glass(p: Palette, shape: Shape = RoundedCornerShape(50), tint: Color = p.glass, elevation: Dp = 0.dp): Modifier =
    this
        .then(if (elevation > 0.dp) Modifier.shadow(elevation, shape, ambientColor = Color(0x40000000), spotColor = Color(0x40000000)) else Modifier)
        .clip(shape)
        .background(tint)
        .background(Brush.verticalGradient(listOf(p.sheen, Color.Transparent, Color.Transparent, Color.Black.copy(alpha = if (p.dark) 0.12f else 0.03f))))
        .border(
            BorderStroke(1.dp, Brush.linearGradient(listOf(p.rimTop, p.rimMid, p.rimEdge, p.rimTop.copy(alpha = p.rimTop.alpha * 0.7f)), start = Offset.Zero, end = Offset.Infinite)),
            shape,
        )
