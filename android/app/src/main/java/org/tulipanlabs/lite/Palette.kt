// SPDX-License-Identifier: GPL-3.0-only
package org.tulipanlabs.lite

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.ColorFilter
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.drawable.Drawable
import kotlin.math.exp
import kotlin.math.hypot

// Iris's one look, the desktop's light Liquid Glass: frosted white panes,
// near-black ink and a blue focus ring, over one of the desktop's own
// backgrounds (the same ids and the same fields of light, so sync keeps the
// choice). A Palette is that look over one background. Colors are ARGB ints.

class Palette(
    val id: String,
    val label: String,
    base: String,
    /** the fields of light: x, y and radius in the picture's size, color, strength */
    val blobs: List<Blob>,
) {
    class Blob(val x: Float, val y: Float, val r: Float, val color: Int, val k: Float)

    /** one look only: light */
    val dark = false
    val base: Int = hex(base)
    private val ink = hex("#1d1d1f")

    /** the background's colors, top to bottom (for gradients drawn in HTML) */
    val grad: List<Int> = listOf(mix(blobs[0].color, this.base, 0.35f), this.base, mix(blobs.last().color, this.base, 0.35f))

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
    private val pale = mix(this.base, WHITE, 0.55f)
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

    /** the window's frame around the page: the background itself */
    val frame = this.base

    fun frameDrawable(): Drawable = WallDrawable(this, 0f)

    /** the colors of Iris's own pages (new tab, results) */
    val pageColors: List<Int> = grad.map { mix(it, WHITE, 0.45f) }

    /** Iris's own pages: the background under a light veil */
    fun pageDrawable(): Drawable = WallDrawable(this, 0.35f)

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

        private fun b(x: Float, y: Float, r: Float, c: String, k: Float) = Blob(x, y, r, hex(c), k)

        /** the desktop's backgrounds (ui/wall.go), Sky first: the default */
        val all: List<Palette> = listOf(
            Palette("sky", "Sky", "#eef4ff", listOf(b(0.12f, 0.10f, 0.55f, "#8ab4ff", 0.75f), b(0.88f, 0.22f, 0.50f, "#c7b5ff", 0.65f), b(0.55f, 0.95f, 0.60f, "#9ee3ff", 0.60f))),
            Palette("dawn", "Dawn", "#fff4ee", listOf(b(0.15f, 0.15f, 0.55f, "#ffb199", 0.70f), b(0.85f, 0.20f, 0.50f, "#ffd59e", 0.70f), b(0.50f, 0.95f, 0.60f, "#f7a8cf", 0.60f))),
            Palette("meadow", "Meadow", "#effaf3", listOf(b(0.10f, 0.20f, 0.55f, "#97e0bd", 0.70f), b(0.90f, 0.15f, 0.50f, "#c9f0a5", 0.60f), b(0.60f, 0.95f, 0.60f, "#a3d6ff", 0.55f))),
            Palette("lilac", "Lilac", "#f5f0ff", listOf(b(0.15f, 0.10f, 0.55f, "#c9b3ff", 0.75f), b(0.90f, 0.30f, 0.50f, "#f6b6e2", 0.60f), b(0.40f, 0.95f, 0.60f, "#b5c6ff", 0.60f))),
            Palette("sand", "Sand", "#f8f4ec", listOf(b(0.15f, 0.15f, 0.55f, "#ead1a8", 0.70f), b(0.85f, 0.25f, 0.50f, "#f5c8a6", 0.55f), b(0.55f, 0.95f, 0.60f, "#d6e3c3", 0.55f))),
            Palette("mist", "Mist", "#f1f3f6", listOf(b(0.15f, 0.10f, 0.55f, "#cdd5e1", 0.70f), b(0.85f, 0.30f, 0.50f, "#e1e5ec", 0.60f), b(0.50f, 0.95f, 0.60f, "#bfcadb", 0.60f))),
        )

        val containerColors = listOf("blue", "turquoise", "green", "yellow", "orange", "red", "pink", "purple")

        /** a background by id; an old palette (from before Liquid Glass) or an unknown id is Sky */
        fun byId(id: String?): Palette = all.firstOrNull { it.id == id } ?: all[0]
    }
}

/**
 * A background drawn as the desktop draws it: soft fields of light on a pale
 * base, rendered once small (the fields are wide and soft) and scaled up,
 * with an optional white veil on top.
 */
class WallDrawable(private val p: Palette, private val veil: Float) : Drawable() {
    private val paint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.DITHER_FLAG)
    private val veilPaint = Paint().also { it.color = Palette.alpha(Palette.WHITE, veil) }
    private var bmp: Bitmap? = null
    private val dst = Rect()

    override fun draw(c: Canvas) {
        val b = bounds
        if (b.width() <= 0 || b.height() <= 0) return
        // the picture keeps the screen's shape, so the fields stay round
        val w = 120
        val h = (w * b.height() / b.width().toFloat()).toInt().coerceIn(40, 480)
        val bm = bmp?.takeIf { it.width == w && it.height == h } ?: render(w, h).also { bmp = it }
        dst.set(b)
        c.drawBitmap(bm, null, dst, paint)
        if (veil > 0f) c.drawRect(b, veilPaint)
    }

    private fun render(w: Int, h: Int): Bitmap {
        val px = IntArray(w * h)
        val diag = hypot(w.toFloat(), h.toFloat())
        val br = p.base shr 16 and 0xff
        val bgc = p.base shr 8 and 0xff
        val bb = p.base and 0xff
        for (y in 0 until h) for (x in 0 until w) {
            var r = br.toFloat()
            var g = bgc.toFloat()
            var bl = bb.toFloat()
            for (f in p.blobs) {
                val dx = x - f.x * w
                val dy = y - f.y * h
                val rr = f.r * diag
                val t = exp(-(dx * dx + dy * dy) / (0.5f * rr * rr)) * f.k
                r += ((f.color shr 16 and 0xff) - r) * t
                g += ((f.color shr 8 and 0xff) - g) * t
                bl += ((f.color and 0xff) - bl) * t
            }
            px[y * w + x] = (0xff shl 24) or (r.toInt().coerceIn(0, 255) shl 16) or (g.toInt().coerceIn(0, 255) shl 8) or bl.toInt().coerceIn(0, 255)
        }
        return Bitmap.createBitmap(px, w, h, Bitmap.Config.ARGB_8888)
    }

    override fun setAlpha(alpha: Int) { paint.alpha = alpha }
    override fun setColorFilter(cf: ColorFilter?) { paint.colorFilter = cf }
    @Deprecated("Deprecated in Java")
    override fun getOpacity(): Int = PixelFormat.OPAQUE
}
