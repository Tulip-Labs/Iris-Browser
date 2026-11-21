// SPDX-License-Identifier: GPL-3.0-only
package org.tulipanlabs.lite

import android.graphics.drawable.Drawable

// Iris's one look, the desktop's light Liquid Glass: frosted white panes,
// near-black ink and a blue focus ring over the desktop's own pale wash
// (ui/theme.go: three colors merging from top to bottom). Colors are ARGB
// ints.

class Palette private constructor(
    /** the window's wash: three colors merging from top to bottom */
    val grad: List<Int>,
) {
    /** one look only: light */
    val dark = false
    private val base: Int = grad[1]
    private val ink = hex("#1d1d1f")

    val onSurface = alpha(ink, 0.94f)
    val onSurfaceVariant = alpha(ink, 0.60f)
    val faint = alpha(ink, 0.38f)
    /** accents read as the ink itself; filled buttons are ink with white on top */
    val primary = onSurface
    val onPrimary = WHITE
    /** the ring around whatever has the keyboard (the desktop's Focus) */
    val focus = hex("#007aff")
    val hl = alpha(ink, 0.85f)
    val danger = hex("#d70015")
    private val pale = mix(base, WHITE, 0.55f)
    /** solid surfaces for sheets and dialogs over a page */
    val surface = pale
    val surfaceHigh = mix(pale, WHITE, 0.45f)
    val surfaceHighest = mix(pale, BLACK, 0.04f)
    /** frosted panes over the background */
    val primaryContainer = alpha(WHITE, 0.62f)
    val onPrimaryContainer = onSurface
    val secondaryContainer = alpha(WHITE, 0.50f)
    val onSecondaryContainer = onSurface
    val outline = alpha(ink, 0.24f)
    val outlineVariant = alpha(ink, 0.10f)
    val divider = alpha(ink, 0.08f)
    val field = alpha(WHITE, 0.82f)
    val ripple = alpha(ink, 0.12f)
    val scrim = alpha(BLACK, 0.32f)
    /** the glass rim along a pane's top edge */
    val rim = alpha(WHITE, 0.85f)
    /** the glass band the bars sit on, and the selected tab's glass */
    val band = alpha(WHITE, 0.46f)
    val tabGlass = alpha(WHITE, 0.74f)

    /** the window's frame around the page: the wash */
    val frame = base

    fun frameDrawable(): Drawable =
        android.graphics.drawable.GradientDrawable(android.graphics.drawable.GradientDrawable.Orientation.TOP_BOTTOM, grad.toIntArray())

    /** the colors of Iris's own pages (the new tab page): the wash, paler */
    val pageColors: List<Int> = listOf(mix(grad[0], WHITE, 0.62f), mix(grad[1], WHITE, 0.7f), mix(grad[2], WHITE, 0.62f))

    fun pageDrawable(): Drawable =
        android.graphics.drawable.GradientDrawable(android.graphics.drawable.GradientDrawable.Orientation.TOP_BOTTOM, pageColors.toIntArray())

    /** a container's color: colorless glass (containers tell apart by their names) */
    @Suppress("UNUSED_PARAMETER")
    fun tone(name: String): Int = hex("#636366")

    companion object {
        const val WHITE = 0xffffffff.toInt()
        const val BLACK = 0xff000000.toInt()

        fun hex(s: String): Int = (0xff000000 or s.removePrefix("#").toLong(16)).toInt()

        fun mix(c: Int, d: Int, t: Float): Int {
            fun ch(shift: Int): Int {
                val p = (c ushr shift) and 0xff
                val q = (d ushr shift) and 0xff
                return (p + (q - p) * t).toInt().coerceIn(0, 255)
            }
            return (ch(24) shl 24) or (ch(16) shl 16) or (ch(8) shl 8) or ch(0)
        }

        fun alpha(c: Int, a: Float): Int = ((a * 255).toInt().coerceIn(0, 255) shl 24) or (c and 0xffffff)

        /** the one look: the desktop's wash (ui/theme.go) */
        val glass = Palette(listOf(hex("#edf3fc"), hex("#f6f6f9"), hex("#f2f2f7")))

        val containerColors = listOf("blue", "turquoise", "green", "yellow", "orange", "red", "pink", "purple")
    }
}
