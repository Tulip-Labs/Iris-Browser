// SPDX-License-Identifier: GPL-3.0-only
package org.tulipanlabs.lite

import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.TextView

// Small building blocks for Lite's Material 3 look, drawn with Android's own
// views (no extra libraries: the app stays small and light).

fun Context.dp(v: Float): Int = (v * resources.displayMetrics.density + 0.5f).toInt()
fun Context.dp(v: Int): Int = dp(v.toFloat())

fun rounded(color: Int, radius: Float, strokeWidth: Int = 0, strokeColor: Int = 0): GradientDrawable {
    val d = GradientDrawable()
    d.shape = GradientDrawable.RECTANGLE
    d.cornerRadius = radius
    d.setColor(color)
    if (strokeWidth > 0) d.setStroke(strokeWidth, strokeColor)
    return d
}

fun oval(color: Int): GradientDrawable {
    val d = GradientDrawable()
    d.shape = GradientDrawable.OVAL
    d.setColor(color)
    return d
}

/** a touch ripple in the palette's color over content (or a bare ripple with the given mask) */
fun ripple(p: Palette, content: Drawable?, mask: Drawable?): RippleDrawable =
    RippleDrawable(ColorStateList.valueOf(p.ripple), content, mask)

fun lp(w: Int, h: Int, weight: Float = 0f): LinearLayout.LayoutParams = LinearLayout.LayoutParams(w, h, weight)
fun flp(w: Int, h: Int, gravity: Int = Gravity.NO_GRAVITY): FrameLayout.LayoutParams = FrameLayout.LayoutParams(w, h, gravity)

const val MATCH = ViewGroup.LayoutParams.MATCH_PARENT
const val WRAP = ViewGroup.LayoutParams.WRAP_CONTENT

/** a 48dp round icon button */
fun Context.iconButton(p: Palette, icon: Int, label: String, tint: Int = p.onSurfaceVariant, onClick: () -> Unit): ImageButton {
    val b = ImageButton(this)
    b.setImageResource(icon)
    b.imageTintList = ColorStateList.valueOf(tint)
    b.contentDescription = label
    b.background = ripple(p, null, oval(Palette.WHITE))
    val pad = dp(12)
    b.setPadding(pad, pad, pad, pad)
    b.scaleType = android.widget.ImageView.ScaleType.FIT_CENTER
    b.setOnClickListener { onClick() }
    b.setOnLongClickListener { android.widget.Toast.makeText(this, label, android.widget.Toast.LENGTH_SHORT).show(); true }
    return b
}

fun Context.text(s: String, sizeSp: Float, color: Int, bold: Boolean = false): TextView {
    val t = TextView(this)
    t.text = s
    t.textSize = sizeSp
    t.setTextColor(color)
    if (bold) t.typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
    return t
}

/** an M3 filter chip */
fun Context.chip(p: Palette, label: String, icon: Int, selected: Boolean, onClick: () -> Unit): TextView {
    val t = text(label, 13.5f, if (selected) p.onSecondaryContainer else p.onSurfaceVariant, bold = true)
    t.gravity = Gravity.CENTER_VERTICAL
    t.setPadding(dp(12), 0, dp(14), 0)
    t.minHeight = dp(36)
    if (icon != 0) {
        val d = getDrawable(icon)?.mutate()
        d?.setTint(if (selected) p.onSecondaryContainer else p.onSurfaceVariant)
        d?.setBounds(0, 0, dp(18), dp(18))
        t.setCompoundDrawables(d, null, null, null)
        t.compoundDrawablePadding = dp(8)
    }
    val bg = if (selected) rounded(p.secondaryContainer, dp(10).toFloat()) else rounded(0, dp(10).toFloat(), dp(1), p.outline)
    t.background = ripple(p, bg, rounded(Palette.WHITE, dp(10).toFloat()))
    t.setOnClickListener { onClick() }
    return t
}

/** a filled or tonal M3 button */
fun Context.button(p: Palette, label: String, filled: Boolean, onClick: () -> Unit): TextView {
    val t = text(label, 14f, if (filled) p.onPrimary else p.onSecondaryContainer, bold = true)
    t.gravity = Gravity.CENTER
    t.setPadding(dp(18), 0, dp(18), 0)
    t.minHeight = dp(40)
    val bg = rounded(if (filled) p.primary else p.secondaryContainer, dp(20).toFloat())
    t.background = ripple(p, bg, rounded(Palette.WHITE, dp(20).toFloat()))
    t.setOnClickListener { onClick() }
    return t
}

/** Lite's mark: a rounded tile in the accent with a ring in motion and a spark. */
class LogoView(ctx: Context, var palette: Palette) : View(ctx) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val r = RectF()

    override fun onDraw(c: Canvas) {
        val w = width.toFloat()
        val s = w / 24f
        r.set(0f, 0f, w, height.toFloat())
        paint.style = Paint.Style.FILL
        paint.shader = LinearGradient(0f, 0f, w, w, Palette.mix(palette.primary, Palette.WHITE, 0.18f), Palette.mix(palette.primary, Palette.BLACK, 0.12f), Shader.TileMode.CLAMP)
        c.drawRoundRect(r, w * 0.3f, w * 0.3f, paint)
        paint.shader = null
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = 2.1f * s
        paint.strokeCap = Paint.Cap.ROUND
        paint.color = Palette.WHITE
        val cx = w / 2
        val cy = height / 2f
        r.set(cx - 6.6f * s, cy - 6.6f * s, cx + 6.6f * s, cy + 6.6f * s)
        c.drawArc(r, 140f, 330f, false, paint)
        paint.style = Paint.Style.FILL
        paint.color = palette.hl
        c.drawCircle(17.2f * s, 7.4f * s, 2.3f * s, paint)
        paint.color = Palette.WHITE
        c.drawCircle(cx, cy, 1.6f * s, paint)
    }
}

/** the thin loading line under the address bar */
class ProgressLine(ctx: Context) : View(ctx) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    var color = 0
    private var shown = 0f
    var progress = 0f
        set(v) {
            field = v
            if (v <= 0f || v >= 1f) shown = v
            invalidate()
        }

    override fun onDraw(c: Canvas) {
        if (progress <= 0f || progress >= 1f) return
        shown += (progress - shown) * 0.25f
        paint.color = color
        val h = height.toFloat()
        c.drawRoundRect(0f, 0f, width * shown.coerceIn(0.06f, 1f), h, h / 2, h / 2, paint)
        if (shown < progress - 0.002f) postInvalidateOnAnimation()
    }
}

/** Lays its children out in centered rows that wrap. */
class Flow(ctx: Context, private val gap: Int) : ViewGroup(ctx) {
    override fun onMeasure(ws: Int, hs: Int) {
        val maxW = MeasureSpec.getSize(ws)
        var x = 0
        var y = 0
        var rowH = 0
        for (i in 0 until childCount) {
            val c = getChildAt(i)
            c.measure(MeasureSpec.makeMeasureSpec(maxW, MeasureSpec.AT_MOST), MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED))
            if (x > 0 && x + c.measuredWidth > maxW) {
                x = 0
                y += rowH + gap
                rowH = 0
            }
            x += c.measuredWidth + gap
            rowH = maxOf(rowH, c.measuredHeight)
        }
        setMeasuredDimension(maxW, y + rowH)
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        val maxW = r - l
        var i = 0
        var y = 0
        while (i < childCount) {
            // one row: as many as fit, centered
            var w = 0
            var h = 0
            var j = i
            while (j < childCount) {
                val c = getChildAt(j)
                val add = if (j > i) gap + c.measuredWidth else c.measuredWidth
                if (j > i && w + add > maxW) break
                w += add
                h = maxOf(h, c.measuredHeight)
                j++
            }
            var x = (maxW - w) / 2
            for (k in i until j) {
                val c = getChildAt(k)
                c.layout(x, y, x + c.measuredWidth, y + c.measuredHeight)
                x += c.measuredWidth + gap
            }
            y += h + gap
            i = j
        }
    }
}

/** a site's colored monogram tile, for tabs and suggestions */
fun siteColor(host: String): Int {
    val pal = listOf("#4f6bd8", "#c2457a", "#2f8f6b", "#b9741f", "#7b55c7", "#2a8fb0", "#b8403a", "#5d7a2b")
    var h = 0x811c9dc5.toInt()
    for (ch in host.removePrefix("www.")) h = (h xor ch.code) * 16777619
    return Palette.hex(pal[(h.toLong() and 0xffffffffL).rem(pal.size).toInt()])
}

fun monogram(host: String): String =
    host.removePrefix("www.").removePrefix("m.").firstOrNull()?.uppercaseChar()?.toString() ?: "?"
