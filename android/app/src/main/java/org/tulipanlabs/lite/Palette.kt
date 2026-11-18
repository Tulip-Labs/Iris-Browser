// SPDX-License-Identifier: GPL-3.0-only
package org.tulipanlabs.lite

// Iris's palettes: the desktop's clear liquid glass (the same ids, so sync
// keeps the choice), turned into Material 3 roles. Only the backdrop has a
// color; text, icons and controls are colorless glass, white light on the
// dark ones and smoked glass on the light ones. Colors are ARGB ints.

class Palette(
    val id: String,
    val label: String,
    val dark: Boolean,
    /** the backdrop: three colors merging from top to bottom behind the window */
    bg: List<Int>,
) {
    /** the backdrop's colors, top to bottom */
    val grad: List<Int> = bg
    private val glass = if (dark) hex("#f5f5f7") else hex("#1d1d1f")
    private val base = if (dark) bg[1] else mix(bg[1], WHITE, 0.55f)

    val onSurface = alpha(glass, if (dark) 0.96f else 0.94f)
    val onSurfaceVariant = alpha(glass, if (dark) 0.62f else 0.60f)
    val faint = alpha(glass, if (dark) 0.40f else 0.38f)
    /** accents read as the ink itself; filled buttons are the ink with the backdrop's color on top */
    val primary = onSurface
    val onPrimary = if (dark) hex("#1d1d1f") else WHITE
    val hl = alpha(glass, 0.85f)
    val danger = if (dark) hex("#ff6961") else hex("#d70015")
    /** solid surfaces for sheets and dialogs over a page */
    val surface = if (dark) mix(base, WHITE, 0.04f) else base
    val surfaceHigh = if (dark) mix(base, WHITE, 0.10f) else mix(base, WHITE, 0.45f)
    val surfaceHighest = if (dark) mix(base, WHITE, 0.15f) else mix(base, BLACK, 0.04f)
    /** frosted panes over the backdrop */
    val primaryContainer = if (dark) alpha(WHITE, 0.14f) else alpha(WHITE, 0.62f)
    val onPrimaryContainer = onSurface
    val secondaryContainer = if (dark) alpha(WHITE, 0.09f) else alpha(WHITE, 0.50f)
    val onSecondaryContainer = onSurface
    val outline = alpha(glass, if (dark) 0.30f else 0.24f)
    val outlineVariant = alpha(glass, if (dark) 0.14f else 0.10f)
    val divider = alpha(glass, if (dark) 0.12f else 0.08f)
    val field = if (dark) alpha(WHITE, 0.08f) else alpha(WHITE, 0.82f)
    val ripple = alpha(glass, if (dark) 0.22f else 0.12f)
    val scrim = alpha(BLACK, if (dark) 0.55f else 0.32f)
    /** the glass rim along a pane's top edge */
    val rim = if (dark) alpha(WHITE, 0.18f) else alpha(WHITE, 0.85f)
    /** the swatch in the palette picker: the backdrop */
    val swatch: List<Int> = bg

    /** The window's frame around the page (bars, tab grid): the backdrop at its top. */
    val frame = if (dark) mix(bg[0], BLACK, 0.35f) else mix(bg[0], WHITE, 0.35f)

    /** the frame as a drawable: the backdrop's colors merging */
    fun frameDrawable(): android.graphics.drawable.Drawable =
        android.graphics.drawable.GradientDrawable(android.graphics.drawable.GradientDrawable.Orientation.TOP_BOTTOM,
            (if (dark) grad.map { mix(it, BLACK, 0.2f) } else grad).toIntArray())

    /** the colors of Iris's own pages (new tab, results) */
    val pageColors: List<Int> = if (dark) grad else grad.map { mix(it, WHITE, 0.55f) }

    fun pageDrawable(): android.graphics.drawable.Drawable =
        android.graphics.drawable.GradientDrawable(android.graphics.drawable.GradientDrawable.Orientation.TOP_BOTTOM, pageColors.toIntArray())

    /** a container's color: colorless glass (containers tell apart by their names) */
    @Suppress("UNUSED_PARAMETER")
    fun tone(name: String): Int = if (dark) hex("#8e8e93") else hex("#636366")

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

        private fun p(id: String, label: String, dark: Boolean, vararg bg: String) = Palette(id, label, dark, bg.map(::hex))

        /** the desktop's palettes; for the dark ones a field of light, the base and a second field */
        val all: List<Palette> = listOf(
            p("liquid", "Liquid", true, "#071a3a", "#000000", "#1b0f2c"),
            p("graphite", "Graphite", true, "#2a1838", "#141416", "#2a1d33"),
            p("deepsea", "Deep Sea", true, "#06324a", "#020a12", "#16153f"),
            p("ember", "Ember", true, "#3d1806", "#0a0503", "#36130e"),
            p("aurora", "Aurora", true, "#0b3a2a", "#030b08", "#2a1648"),
            p("daylight", "Daylight", false, "#eaf2ff", "#f6f3ff", "#f5f5f7"),
            p("mist", "Mist", false, "#dbe6ff", "#ece2ff", "#f6f0fb"),
            p("rose", "Rose", false, "#ffe2ea", "#fff0e8", "#f4e9ff"),
            p("sunrise", "Sunrise", false, "#ffe8cc", "#ffdfd9", "#fff6e6"),
            p("mint", "Mint", false, "#d8f7ee", "#e2efff", "#f4fbf9"),
        )

        val containerColors = listOf("blue", "turquoise", "green", "yellow", "orange", "red", "pink", "purple")

        /** a palette by id; an old or unknown one is Liquid */
        fun byId(id: String?): Palette = all.firstOrNull { it.id == id } ?: all[0]
    }
}
