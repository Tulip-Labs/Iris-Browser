package org.tulipanlabs.iris.ui

import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.addPathNodes
import androidx.compose.ui.unit.dp

/** Iris's own line icons (24 × 24, stroked; the same family as Ember's and
 *  the desktop's), tinted where they are drawn */
enum class Glyph(val d: String, val fill: String? = null, val width: Float = 1.8f) {
    BACK("M15 5l-7 7 7 7"),
    FORWARD("M9 5l7 7-7 7"),
    HOME("M4 11l8-7 8 7M6 9.5V20h12V9.5M10 20v-5h4v5"),
    PLUS("M12 5v14M5 12h14"),
    CLOSE("M6.5 6.5l11 11M17.5 6.5l-11 11"),
    RELOAD("M20 12a8 8 0 1 1-2.6-5.9M20 4v5h-5"),
    SHIELD("M12 3l7.5 3v5.5c0 4.6-3.2 8.2-7.5 9.5-4.3-1.3-7.5-4.9-7.5-9.5V6z"),
    SHIELD_ON("M12 3l7.5 3v5.5c0 4.6-3.2 8.2-7.5 9.5-4.3-1.3-7.5-4.9-7.5-9.5V6zM8.8 12l2.2 2.2 4.3-4.4"),
    LAYERS("M12 4l9 4.5-9 4.5-9-4.5zM3 13l9 4.5 9-4.5"),
    DOWNLOAD("M12 4v11M7.5 10.5L12 15l4.5-4.5M5 20h14"),
    LOCK("M6 11h12v9H6zM8.5 11V8a3.5 3.5 0 0 1 7 0v3"),
    MORE("M5.5 12v.1M12 12v.1M18.5 12v.1", width = 3f),
    TABS("M7 7V4.5h12.5V17H17M4.5 7H17v12.5H4.5z"),
    COPY("M8 8h11.5v11.5H8zM16 8V4.5H4.5V16H8"),
    SHARE("M12 15V4M7.5 8.5L12 4l4.5 4.5M5 13v6.5h14V13"),
    IMAGE("M3 5h18v14H3zM3 16l5-5 4 4 3-3 6 6M15.5 9v.2"),
    OPEN("M7 17L17 7M9 7h8v8"),
    TRASH("M4.5 7h15M9.5 7V4.5h5V7M6.5 7l1 12.5h9l1-12.5"),
    GLOBE("M12 3a9 9 0 1 0 0 18a9 9 0 1 0 0-18M3 12h18M12 3c2.5 2.6 3.7 5.6 3.7 9s-1.2 6.4-3.7 9c-2.5-2.6-3.7-5.6-3.7-9S9.5 5.6 12 3z"),
    CHECK("M5 12.5l4.5 4.5L19 7.5"),
    SEARCH("M11 4a7 7 0 1 0 0 14a7 7 0 1 0 0-14M16.2 16.2L20.5 20.5"),
    SUN("M12 8a4 4 0 1 0 0 8a4 4 0 1 0 0-8M12 2.5v2M12 19.5v2M5.3 5.3l1.4 1.4M17.3 17.3l1.4 1.4M2.5 12h2M19.5 12h2M5.3 18.7l1.4-1.4M17.3 6.7l1.4-1.4"),
    MOON("M20.5 14.5A8.5 8.5 0 0 1 9.5 3.5a8.5 8.5 0 1 0 11 11z"),
    AUTO("M12 3a9 9 0 1 0 0 18a9 9 0 1 0 0-18", fill = "M12 3a9 9 0 0 0 0 18z"),
    EYE_OFF("M3.5 3.5l17 17M10.6 6.1A9.8 9.8 0 0 1 12 6c5 0 9 6 9 6a16 16 0 0 1-2.6 3.1M6.6 7.6C4.2 9.2 3 12 3 12s4 6 9 6a8.6 8.6 0 0 0 4.3-1.2M9.9 10a3 3 0 0 0 4.1 4.2"),
    HISTORY("M4 12a8 8 0 1 0 2.4-5.7M4 4v4.5h4.5M12 8v4.5l3 2"),
    UPDATE("M12 20V9M7.5 13.5L12 9l4.5 4.5M5 4h14"),
    INFO("M12 3a9 9 0 1 0 0 18a9 9 0 1 0 0-18M12 11v5.5M12 7.5v.2"),
    // containers
    PERSON("M12 12a4 4 0 1 0 0-8a4 4 0 1 0 0 8M4.5 20a7.5 7.5 0 0 1 15 0"),
    BRIEFCASE("M3.5 8h17v11h-17zM8.5 8V5.5h7V8M3.5 13h17"),
    CART("M3 4h2.5l2 11h10.5l2-8H6.5M9 19.5a1.2 1.2 0 1 0 2.4 0a1.2 1.2 0 1 0-2.4 0M16 19.5a1.2 1.2 0 1 0 2.4 0a1.2 1.2 0 1 0-2.4 0"),
    BANK("M3 9.5L12 4l9 5.5M5 10v8M9.7 10v8M14.3 10v8M19 10v8M3 20.5h18"),
    HEART("M12 20s-7.5-4.6-7.5-10a4.3 4.3 0 0 1 7.5-2.8A4.3 4.3 0 0 1 19.5 10c0 5.4-7.5 10-7.5 10z"),
    GAME("M7 8h10a4 4 0 0 1 4 4.5l-.6 3.2a2.2 2.2 0 0 1-3.9.9L15 15H9l-1.5 1.6a2.2 2.2 0 0 1-3.9-.9L3 12.5A4 4 0 0 1 7 8zM8 10.5v3M6.5 12h3M15.5 11.2v.1M17 12.8v.1"),
    BOOK("M4 5.5A1.5 1.5 0 0 1 5.5 4H11v15.5H5.5A1.5 1.5 0 0 0 4 21zM20 5.5A1.5 1.5 0 0 0 18.5 4H13v15.5h5.5A1.5 1.5 0 0 1 20 21z"),
    PLANE("M21 4L3 11.5l7 2.5 2.5 7L21 4zM10 14l4.5-4.5"),
    CODE("M8.5 7L3.5 12l5 5M15.5 7l5 5-5 5M13.5 5l-3 14"),
    MUSIC("M9 18V5.5l11-2V16M9 18a2.5 2.5 0 1 1-5 0a2.5 2.5 0 1 1 5 0M20 16a2.5 2.5 0 1 1-5 0a2.5 2.5 0 1 1 5 0"),
    STAR("M12 3.5l2.6 5.3 5.9.9-4.3 4.1 1 5.8L12 16.9l-5.2 2.7 1-5.8-4.3-4.1 5.9-.9z"),
}

object Glyphs {
    private val cache = HashMap<Glyph, ImageVector>()

    fun vector(g: Glyph): ImageVector = cache.getOrPut(g) {
        val b = ImageVector.Builder(name = g.name, defaultWidth = 24.dp, defaultHeight = 24.dp, viewportWidth = 24f, viewportHeight = 24f)
        g.fill?.let { b.addPath(pathData = addPathNodes(it), fill = SolidColor(Color.Black)) }
        b.addPath(
            pathData = addPathNodes(g.d), fill = null, stroke = SolidColor(Color.Black), strokeLineWidth = g.width,
            strokeLineCap = StrokeCap.Round, strokeLineJoin = StrokeJoin.Round,
        )
        b.build()
    }

    /** a container's icon */
    fun container(name: String): Glyph = when (name) {
        "person" -> Glyph.PERSON
        "briefcase" -> Glyph.BRIEFCASE
        "cart" -> Glyph.CART
        "bank" -> Glyph.BANK
        "home" -> Glyph.HOME
        "heart" -> Glyph.HEART
        "game" -> Glyph.GAME
        "book" -> Glyph.BOOK
        "plane" -> Glyph.PLANE
        "code" -> Glyph.CODE
        "music" -> Glyph.MUSIC
        "private" -> Glyph.EYE_OFF
        else -> Glyph.STAR
    }
}
