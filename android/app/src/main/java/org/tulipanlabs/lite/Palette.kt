// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
package org.tulipanlabs.lite

// Lite's palettes: Flowcode's spring themes (the same as Lite Go on the
// desktop), turned into Material 3 roles. Colors are ARGB ints.

class Palette(
    val id: String,
    val label: String,
    val dark: Boolean,
    ink: Int, ink2: Int, ink3: Int,
    deep: Int, deep2: Int, val hl: Int, val danger: Int,
    g5: Int, val swatch: List<Int>,
) {
    val primary = deep
    val onPrimary = WHITE
    val onSurface = ink
    val onSurfaceVariant = ink2
    val faint = ink3
    val surface = g5
    val surfaceHigh = if (dark) mix(g5, WHITE, 0.09f) else mix(g5, deep, 0.06f)
    val surfaceHighest = if (dark) mix(g5, WHITE, 0.14f) else mix(g5, deep, 0.09f)
    val primaryContainer = if (dark) mix(deep, g5, 0.55f) else mix(deep, WHITE, 0.82f)
    val onPrimaryContainer = if (dark) mix(deep, WHITE, 0.8f) else mix(deep, BLACK, 0.45f)
    val secondaryContainer = if (dark) mix(deep2, g5, 0.65f) else mix(deep2, WHITE, 0.80f)
    val onSecondaryContainer = if (dark) mix(deep2, WHITE, 0.85f) else mix(deep2, BLACK, 0.5f)
    val outline = alpha(ink, if (dark) 0.36f else 0.28f)
    val outlineVariant = alpha(ink, if (dark) 0.16f else 0.10f)
    val divider = alpha(ink, if (dark) 0.14f else 0.08f)
    val field = if (dark) alpha(WHITE, 0.07f) else alpha(WHITE, 0.85f)
    val ripple = alpha(deep, if (dark) 0.28f else 0.16f)
    val scrim = alpha(BLACK, if (dark) 0.55f else 0.32f)

    /** The window's frame around the page (bars, tab grid). */
    val frame = if (dark) mix(g5, BLACK, 0.25f) else surfaceHigh

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

        private fun spring(
            id: String, label: String, ink: String, ink2: String, ink3: String,
            deep: String, deep2: String, hl: String, danger: String, g5: String, sw: List<String>,
        ) = Palette(id, label, false, hex(ink), hex(ink2), hex(ink3), hex(deep), hex(deep2), hex(hl), hex(danger), hex(g5), sw.map(::hex))

        val all: List<Palette> = listOf(
            spring("crocus", "Crocus", "#2a1433", "#7d6487", "#b9a3c6", "#923993", "#9d60ab", "#ffae00", "#ca3404", "#fffaf7",
                listOf("#923993", "#9d60ab", "#cca2e2", "#ffae00", "#ca3404")),
            spring("tulip", "Tulip", "#2b0f2e", "#85628a", "#c4a6c8", "#922b99", "#bb38bd", "#f69a2f", "#d2264f", "#fff9f4",
                listOf("#922b99", "#bb38bd", "#f04599", "#fed272", "#f69a2f")),
            spring("spring", "Spring Mix", "#241f4e", "#78739e", "#a9a4cf", "#5145c9", "#8f7fe0", "#f7b2d5", "#c8424f", "#fffdf5",
                listOf("#5145c9", "#f8bbd9", "#fce38a", "#d8f3dc", "#a9def9")),
            spring("sakura", "Sakura", "#33171f", "#8c6a74", "#d0aab6", "#c2457a", "#e48aae", "#8fbf6a", "#c0392b", "#fffafa",
                listOf("#c2457a", "#e48aae", "#ffd1df", "#fffafa", "#8fbf6a")),
            spring("meadow", "Meadow", "#12291c", "#66806f", "#a7c0ae", "#2f7d4f", "#5aa86f", "#f5c518", "#c43d2f", "#fbfdf6",
                listOf("#2f7d4f", "#5aa86f", "#f5c518", "#d4f0ff", "#bfe6d0")),
            Palette("classic", "Classic", false, hex("#1d1d24"), hex("#6b6b78"), hex("#a8a8b4"), hex("#3a5bc7"), hex("#6f86d6"),
                hex("#f0a500"), hex("#c62828"), hex("#f7f7f9"), listOf("#3a5bc7", "#e8eefc", "#e3f4e1", "#fff3cf", "#f0a500").map(::hex)),
            Palette("night", "Night", true, hex("#f3e9f7"), hex("#b29fbd"), hex("#7c6a87"), hex("#c07ad0"), hex("#9d60ab"),
                hex("#ffae00"), hex("#ff6b4a"), hex("#17111c"), listOf("#17111c", "#c07ad0", "#9d60ab", "#ffae00", "#ff6b4a").map(::hex)),
        )

        fun byId(id: String?): Palette = all.firstOrNull { it.id == id } ?: all[0]
    }
}
