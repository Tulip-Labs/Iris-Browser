package org.tulipanlabs.iris.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

val IrisViolet = Color(0xFF5B3CC4)
val Ink = Color(0xFF1C1C21)

private val scheme = lightColorScheme(
    primary = IrisViolet,
    onPrimary = Color.White,
    primaryContainer = Color(0xFFE9E2FF),
    onPrimaryContainer = Color(0xFF22125E),
    secondary = Color(0xFF0A84FF),
    background = Color(0xFFF5F4FA),
    surface = Color(0xFFF8F7FC),
    onSurface = Ink,
    surfaceVariant = Color(0xFFECEAF4),
    onSurfaceVariant = Color(0xFF5E5C6B),
    outline = Color(0x22000000),
)

@Composable
fun IrisTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = scheme, content = content)
}

/**
 * Material 3 surfaces with Iris's glass: light that falls from above, a rim
 * of light round the edge and a faint tint, so the chrome reads as glass
 * laid over the page.
 */
fun Modifier.glass(shape: Shape = RoundedCornerShape(50), tint: Color = Color.White.copy(alpha = 0.72f), elevation: Dp = 0.dp): Modifier =
    this
        .then(if (elevation > 0.dp) Modifier.shadow(elevation, shape, ambientColor = Color(0x33000000), spotColor = Color(0x33000000)) else Modifier)
        .clip(shape)
        .background(tint)
        .background(Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.55f), Color.White.copy(alpha = 0.0f), Color.White.copy(alpha = 0.12f))))
        .border(
            BorderStroke(1.dp, Brush.linearGradient(
                listOf(Color.White, Color.White.copy(alpha = 0.25f), Color.Black.copy(alpha = 0.06f), Color.White.copy(alpha = 0.8f)),
                start = Offset.Zero, end = Offset.Infinite,
            )),
            shape,
        )
