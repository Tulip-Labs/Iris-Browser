package org.tulipanlabs.iris.ui

import android.annotation.SuppressLint
import android.content.Context
import android.view.MotionEvent
import android.view.ViewConfiguration
import android.widget.FrameLayout
import org.mozilla.geckoview.GeckoSession
import org.mozilla.geckoview.GeckoView
import org.mozilla.geckoview.PanZoomController

/**
 * The page: a GeckoView, and pull-to-reload over it. GeckoView scrolls the
 * page itself, so it is asked, as each touch begins, whether the page can
 * still scroll up; only when it cannot does pulling down reload.
 */
@SuppressLint("ViewConstructor")
class GeckoHost(context: Context, private val onPull: (Float) -> Unit, private val onRelease: (Boolean) -> Unit) : FrameLayout(context) {
    val gecko = PageView(context)
    private val slop = ViewConfiguration.get(context).scaledTouchSlop
    private var startY = 0f
    private var pulling = false
    private val reach = 140f * context.resources.displayMetrics.density

    init {
        addView(gecko, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        gecko.coverUntilFirstPaint(android.graphics.Color.WHITE)
    }

    fun show(session: GeckoSession?) {
        if (gecko.session === session) return
        if (gecko.session != null) gecko.releaseSession()
        if (session != null) gecko.setSession(session)
    }

    override fun onInterceptTouchEvent(ev: MotionEvent): Boolean {
        when (ev.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                startY = ev.y
                pulling = false
                return false
            }
            MotionEvent.ACTION_MOVE -> {
                if (gecko.atTop && !pulling && ev.y - startY > slop) {
                    pulling = true
                    // the page lets go of this touch; it is a pull now
                    val cancel = MotionEvent.obtain(ev).apply { action = MotionEvent.ACTION_CANCEL }
                    gecko.onTouchEvent(cancel)
                    cancel.recycle()
                    return true
                }
            }
        }
        return false
    }

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(ev: MotionEvent): Boolean {
        if (!pulling) return super.onTouchEvent(ev)
        val f = ((ev.y - startY - slop) / reach).coerceIn(0f, 1.4f)
        when (ev.actionMasked) {
            MotionEvent.ACTION_MOVE -> onPull(f)
            MotionEvent.ACTION_UP -> { pulling = false; onRelease(f >= 1f) }
            MotionEvent.ACTION_CANCEL -> { pulling = false; onRelease(false) }
        }
        return true
    }
}

/** GeckoView that remembers, for each touch, whether the page could scroll
 *  further up (the answer comes with the touch's first event) */
class PageView(context: Context) : GeckoView(context) {
    @Volatile var atTop = false
        private set

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(ev: MotionEvent): Boolean {
        if (ev.actionMasked == MotionEvent.ACTION_DOWN) {
            atTop = false
            onTouchEventForDetailResult(ev).accept { d ->
                if (d != null) atTop = (d.scrollableDirections() and PanZoomController.SCROLLABLE_FLAG_TOP) == 0 &&
                    d.handledResult() != PanZoomController.INPUT_RESULT_HANDLED_CONTENT
            }
            return true
        }
        return super.onTouchEvent(ev)
    }
}
