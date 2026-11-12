// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
package org.tulipanlabs.lite

import android.app.Activity
import android.app.ActivityManager
import android.app.AlertDialog
import android.app.SearchManager
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ComponentCallbacks2
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Message
import android.text.Editable
import android.text.InputType
import android.text.TextUtils
import android.text.TextWatcher
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.webkit.CookieManager
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebStorage
import android.webkit.WebView
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Switch
import android.widget.TextView
import android.widget.Toast
import java.io.File
import java.util.concurrent.Executors

class MainActivity : Activity(), PageEvents {
    private lateinit var set: Settings
    private lateinit var hist: History
    private lateinit var pages: Pages
    private var pal = Palette.all[0]

    private val tabs = ArrayList<Tab>()
    private var cur = -1
    private var nextId = 1L
    private var blockedSession = 0L

    private val ui = Handler(Looper.getMainLooper())
    private val bg = Executors.newSingleThreadExecutor()
    private val net = Executors.newSingleThreadExecutor()

    // views
    private lateinit var root: FrameLayout
    private lateinit var column: LinearLayout
    private lateinit var addr: EditText
    private lateinit var addrIcon: ImageView
    private lateinit var shieldBtn: ImageButton
    private lateinit var badge: TextView
    private lateinit var aiBtn: ImageButton
    private lateinit var progress: ProgressLine
    private lateinit var content: FrameLayout
    private lateinit var bottom: LinearLayout
    private lateinit var backBtn: ImageButton
    private lateinit var fwdBtn: ImageButton
    private lateinit var tabsBtn: TextView
    private var ntp: View? = null
    private var suggest: ScrollView? = null
    private var grid: View? = null
    private var sheet: View? = null
    private var full: View? = null
    private var fullDone: WebChromeClient.CustomViewCallback? = null
    private var fileCb: ValueCallback<Array<Uri>>? = null
    private var insetTop = 0
    private var insetBottom = 0
    private var keyboard = false
    private var suggestSeq = 0

    // ---- lifecycle ----

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        set = Settings(this)
        hist = History(this)
        pal = Palette.byId(set.theme)
        pages = Pages(this, set, this)
        edgeToEdge()
        buildUi()
        restoreSession()
        if (!handleIntent(intent) && tabs.isEmpty()) newTab("", false)
        loadShields(refresh = false)
        ui.postDelayed({ loadShields(refresh = true) }, 8000) // fetch new lists once the first page is up
    }

    override fun onNewIntent(i: Intent) {
        super.onNewIntent(i)
        handleIntent(i)
    }

    override fun onPause() {
        super.onPause()
        saveSession()
        set.blockedTotal = set.blockedTotal + blockedSession
        blockedSession = 0
        tab()?.web?.onPause()
        CookieManager.getInstance().flush()
    }

    override fun onResume() {
        super.onResume()
        tab()?.web?.onResume()
    }

    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        // the system is short of memory: pages in the background go to sleep
        if (level >= ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW) for (t in tabs) if (t !== tab()) shelve(t)
    }

    override fun onDestroy() {
        for (t in tabs) t.web?.destroy()
        super.onDestroy()
    }

    @Deprecated("the system back button")
    override fun onBackPressed() {
        val t = tab()
        when {
            full != null -> onFullscreen(null, null)
            sheet != null -> closeSheet()
            grid != null -> closeGrid()
            addr.hasFocus() -> unfocusAddress()
            t?.web != null && t.web!!.canGoBack() && t.url.isNotEmpty() -> t.web!!.goBack()
            t != null && t.url.isNotEmpty() && tabs.size > 1 && t.private -> closeTab(cur)
            else -> moveTaskToBack(true)
        }
    }

    @Deprecated("file uploads")
    override fun onActivityResult(req: Int, res: Int, data: Intent?) {
        super.onActivityResult(req, res, data)
        if (req == FILES) {
            fileCb?.onReceiveValue(WebChromeClient.FileChooserParams.parseResult(res, data))
            fileCb = null
        }
    }

    // ---- the window ----

    private fun edgeToEdge() {
        val w = window
        w.statusBarColor = 0
        w.navigationBarColor = 0
        if (Build.VERSION.SDK_INT >= 30) w.setDecorFitsSystemWindows(false)
        else @Suppress("DEPRECATION") {
            w.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_LAYOUT_STABLE or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
        }
    }

    /** dark icons on the light themes */
    private fun barIcons() {
        val light = !pal.dark
        if (Build.VERSION.SDK_INT >= 30) {
            val c = window.insetsController ?: return
            val m = WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS
            c.setSystemBarsAppearance(if (light) m else 0, m)
        } else @Suppress("DEPRECATION") {
            var f = View.SYSTEM_UI_FLAG_LAYOUT_STABLE or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
            if (light) f = f or View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR or View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR
            window.decorView.systemUiVisibility = f
        }
    }

    private fun systemBars(show: Boolean) {
        if (Build.VERSION.SDK_INT >= 30) {
            val c = window.insetsController ?: return
            if (show) c.show(WindowInsets.Type.systemBars())
            else {
                c.hide(WindowInsets.Type.systemBars())
                c.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else @Suppress("DEPRECATION") {
            window.decorView.systemUiVisibility = if (show) 0 else
                View.SYSTEM_UI_FLAG_FULLSCREEN or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
            if (show) barIcons()
        }
    }

    // ---- building the interface ----

    private fun buildUi() {
        // keep the pages (they live across a rebuild, when the theme changes)
        for (t in tabs) (t.web?.parent as? ViewGroup)?.removeView(t.web)
        ntp = null
        suggest = null
        grid = null
        sheet = null
        root = FrameLayout(this)
        root.setBackgroundColor(pal.frame)
        // taking the focus when the address bar lets it go (or Android hands it straight back)
        root.isFocusableInTouchMode = true
        column = LinearLayout(this)
        column.orientation = LinearLayout.VERTICAL
        root.addView(column, flp(MATCH, MATCH))

        // the address row: shield, address, AI
        val top = LinearLayout(this)
        top.orientation = LinearLayout.HORIZONTAL
        top.gravity = Gravity.CENTER_VERTICAL
        top.setPadding(dp(4), dp(4), dp(4), dp(4))
        val shieldBox = FrameLayout(this)
        shieldBtn = iconButton(pal, R.drawable.ic_shield, "Lite Shields", pal.primary) { shieldDialog() }
        shieldBox.addView(shieldBtn, flp(dp(48), dp(48)))
        badge = text("", 9.5f, pal.onPrimary, bold = true)
        badge.gravity = Gravity.CENTER
        badge.setPadding(dp(4), 0, dp(4), 0)
        badge.minWidth = dp(16)
        badge.background = rounded(pal.primary, dp(8).toFloat())
        badge.visibility = View.GONE
        shieldBox.addView(badge, flp(WRAP, dp(15), Gravity.TOP or Gravity.END).also { it.topMargin = dp(4); it.rightMargin = dp(2) })
        top.addView(shieldBox, lp(dp(48), dp(48)))

        val pill = LinearLayout(this)
        pill.orientation = LinearLayout.HORIZONTAL
        pill.gravity = Gravity.CENTER_VERTICAL
        pill.background = rounded(pal.field, dp(22).toFloat())
        pill.setPadding(dp(14), 0, dp(6), 0)
        addrIcon = ImageView(this)
        addrIcon.setImageResource(R.drawable.ic_search)
        addrIcon.imageTintList = android.content.res.ColorStateList.valueOf(pal.onSurfaceVariant)
        pill.addView(addrIcon, lp(dp(18), dp(18)))
        addr = EditText(this)
        addr.background = null
        addr.setSingleLine(true)
        addr.textSize = 15.5f
        addr.setTextColor(pal.onSurface)
        addr.setHintTextColor(pal.faint)
        addr.hint = "Search or type an address"
        addr.imeOptions = EditorInfo.IME_ACTION_GO or EditorInfo.IME_FLAG_NO_EXTRACT_UI
        addr.inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
        addr.setSelectAllOnFocus(true)
        addr.setPadding(dp(10), 0, dp(4), 0)
        addr.ellipsize = TextUtils.TruncateAt.END
        addr.setOnEditorActionListener { _, action, ev ->
            if (action == EditorInfo.IME_ACTION_GO || (ev != null && ev.keyCode == KeyEvent.KEYCODE_ENTER && ev.action == KeyEvent.ACTION_DOWN)) {
                go(addr.text.toString())
                true
            } else false
        }
        addr.setOnFocusChangeListener { _, focused -> addressFocus(focused) }
        addr.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun afterTextChanged(s: Editable?) {
                if (addr.hasFocus()) suggestFor(s?.toString() ?: "")
            }
        })
        pill.addView(addr, lp(0, MATCH, 1f))
        top.addView(pill, lp(0, dp(44), 1f).also { it.leftMargin = dp(2); it.rightMargin = dp(2) })
        aiBtn = iconButton(pal, R.drawable.ic_sparkle, "Ask AI about this page", pal.primary) { askAI() }
        top.addView(aiBtn, lp(dp(48), dp(48)))
        column.addView(top, lp(MATCH, WRAP))

        progress = ProgressLine(this)
        progress.color = pal.primary
        column.addView(progress, lp(MATCH, dp(3)))

        content = FrameLayout(this)
        content.setBackgroundColor(pal.surface)
        column.addView(content, lp(MATCH, 0, 1f))

        // the bottom buttons, where the thumb is
        bottom = LinearLayout(this)
        bottom.orientation = LinearLayout.HORIZONTAL
        bottom.gravity = Gravity.CENTER_VERTICAL
        val slot = { v: View -> bottom.addView(v, lp(0, dp(52), 1f)) }
        backBtn = iconButton(pal, R.drawable.ic_back, "Back") { onBackPage() }
        fwdBtn = iconButton(pal, R.drawable.ic_forward, "Forward") { tab()?.web?.let { if (it.canGoForward()) it.goForward() } }
        slot(backBtn)
        slot(fwdBtn)
        slot(iconButton(pal, R.drawable.ic_add, "New tab", pal.primary) { newTab("", false); focusAddress() })
        val tb = FrameLayout(this)
        tabsBtn = text("1", 12f, pal.onSurfaceVariant, bold = true)
        tabsBtn.gravity = Gravity.CENTER
        tabsBtn.background = rounded(0, dp(6).toFloat(), dp(2), pal.onSurfaceVariant)
        tb.addView(tabsBtn, flp(dp(24), dp(24), Gravity.CENTER))
        tb.background = ripple(pal, null, oval(Palette.WHITE))
        tb.contentDescription = "Tabs"
        tb.setOnClickListener { if (grid == null) openGrid() else closeGrid() }
        slot(tb)
        slot(iconButton(pal, R.drawable.ic_more, "Menu") { if (sheet == null) openSheet() else closeSheet() })
        column.addView(bottom, lp(MATCH, WRAP))

        root.setOnApplyWindowInsetsListener { _, ins -> insets(ins); ins }
        setContentView(root)
        root.requestApplyInsets()
        barIcons()
        // the pages back in place
        for (t in tabs) t.web?.let { content.addView(it, 0, flp(MATCH, MATCH)) }
        if (cur >= 0) show()
    }

    private fun insets(ins: WindowInsets) {
        var top: Int
        var bot: Int
        var ime = 0
        if (Build.VERSION.SDK_INT >= 30) {
            val sys = ins.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
            ime = ins.getInsets(WindowInsets.Type.ime()).bottom
            top = sys.top
            bot = maxOf(sys.bottom, ime)
            column.setPadding(sys.left, 0, sys.right, 0)
        } else @Suppress("DEPRECATION") {
            top = ins.systemWindowInsetTop
            bot = ins.systemWindowInsetBottom
            ime = if (bot > dp(120)) bot else 0
        }
        if (full != null) { top = 0; bot = 0 }
        insetTop = top
        insetBottom = bot
        column.setPadding(column.paddingLeft, top, column.paddingRight, bot)
        val kb = ime > dp(120)
        if (kb != keyboard) {
            keyboard = kb
            bottom.visibility = if (kb || addr.hasFocus()) View.GONE else View.VISIBLE
        }
    }

    // ---- tabs ----

    private fun tab(): Tab? = tabs.getOrNull(cur)

    /** how many pages stay loaded at once: the rest sleep (their history is kept) */
    private fun liveLimit(): Int {
        val mb = (getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).memoryClass
        return when {
            mb <= 192 -> 2
            mb <= 384 -> 3
            else -> 5
        }
    }

    private fun newTab(url: String, private: Boolean, select: Boolean = true, after: Int = cur): Tab {
        val t = Tab(nextId++, private)
        val at = if (after in tabs.indices) after + 1 else tabs.size
        tabs.add(at, t)
        if (select) selectTab(at)
        if (url.isNotEmpty()) open(t, url)
        updateBars()
        return t
    }

    private fun selectTab(i: Int) {
        val old = tab()
        if (old != null && old.web != null && i != cur) {
            old.web!!.onPause()
            old.web!!.visibility = View.GONE
        }
        cur = i
        val t = tab() ?: return
        t.lastUsed = System.currentTimeMillis()
        if (t.web == null && (t.saved != null || t.url.isNotEmpty())) wake(t)
        show()
        trim()
    }

    /** the page's WebView, made again from its saved history */
    private fun wake(t: Tab) {
        val w = pages.make(t)
        content.addView(w, 0, flp(MATCH, MATCH))
        val s = t.saved
        t.saved = null
        if (s == null || w.restoreState(s) == null) {
            if (t.url.isNotEmpty()) w.loadUrl(t.url)
        }
    }

    /** puts a background page to sleep: its WebView goes, its history stays */
    private fun shelve(t: Tab) {
        val w = t.web ?: return
        val b = Bundle()
        w.saveState(b)
        t.saved = b
        content.removeView(w)
        w.destroy()
        t.web = null
    }

    private fun trim() {
        val live = tabs.filter { it.web != null && it !== tab() }.sortedBy { it.lastUsed }
        val over = live.size + 1 - liveLimit()
        for (k in 0 until over) shelve(live[k])
    }

    private fun closeTab(i: Int) {
        val t = tabs.getOrNull(i) ?: return
        t.web?.let { content.removeView(it); it.destroy() }
        tabs.removeAt(i)
        if (tabs.isEmpty()) {
            cur = -1
            newTab("", false)
            return
        }
        cur = -1
        selectTab(minOf(i, tabs.size - 1).coerceAtLeast(0))
        updateBars()
    }

    private fun open(t: Tab, url: String) {
        t.url = url
        t.page = url
        val w = t.web ?: pages.make(t).also { content.addView(it, 0, flp(MATCH, MATCH)) }
        w.loadUrl(url)
        if (t === tab()) show()
    }

    /** shows the current tab: its page, or the new tab page */
    private fun show() {
        val t = tab() ?: return
        for (o in tabs) if (o !== t) o.web?.visibility = View.GONE
        val page = t.web != null && t.url.isNotEmpty()
        t.web?.visibility = if (page) View.VISIBLE else View.GONE
        if (page) {
            t.web!!.onResume()
            ntp?.let { content.removeView(it) }
            ntp = null
        } else showNtp()
        updateBars()
    }

    private fun go(text: String) {
        val url = Search.resolve(text, set.mode)
        if (url.isEmpty()) return
        unfocusAddress()
        val t = tab() ?: newTab("", false)
        open(t, url)
    }

    private fun onBackPage() {
        val w = tab()?.web ?: return
        if (w.canGoBack()) w.goBack()
    }

    private fun askAI() {
        val t = tab()
        if (t == null || t.url.isEmpty() || Search.query(t.url) != null) {
            set.mode = Mode.AI
            focusAddress()
            return
        }
        newTab(Search.url("Explain this page: " + t.url, Mode.AI), t.private)
    }

    // ---- the bars ----

    private fun display(url: String): String =
        Search.query(url) ?: url.removePrefix("https://").removePrefix("http://").removePrefix("www.").removeSuffix("/")

    private fun updateBars() {
        val t = tab()
        if (!addr.hasFocus()) {
            addr.setText(if (t == null || t.url.isEmpty()) "" else display(t.url))
            val icon = when {
                t == null || t.url.isEmpty() || Search.query(t.url) != null -> R.drawable.ic_search
                t.url.startsWith("https://") -> R.drawable.ic_lock
                else -> R.drawable.ic_warning
            }
            addrIcon.setImageResource(icon)
            addrIcon.imageTintList = android.content.res.ColorStateList.valueOf(if (icon == R.drawable.ic_warning) pal.danger else pal.onSurfaceVariant)
        }
        backBtn.isEnabled = t?.web?.canGoBack() == true
        backBtn.alpha = if (backBtn.isEnabled) 1f else 0.38f
        fwdBtn.isEnabled = t?.web?.canGoForward() == true
        fwdBtn.alpha = if (fwdBtn.isEnabled) 1f else 0.38f
        tabsBtn.text = if (tabs.size > 99) "99+" else tabs.size.toString()
        val on = t != null && pages.shieldOn(t.url)
        shieldBtn.imageTintList = android.content.res.ColorStateList.valueOf(if (on || t?.url.isNullOrEmpty()) pal.primary else pal.faint)
        val n = t?.blocked ?: 0
        badge.visibility = if (on && n > 0) View.VISIBLE else View.GONE
        badge.text = if (n > 999) "999+" else n.toString()
        progress.progress = if (t == null || t.url.isEmpty() || t.progress >= 100) 0f else t.progress / 100f
        aiBtn.visibility = if (addr.hasFocus()) View.GONE else View.VISIBLE
        tabsBtn.setTextColor(if (t?.private == true) pal.primary else pal.onSurfaceVariant)
    }

    private fun focusAddress() {
        closeGrid()
        closeSheet()
        addr.requestFocus()
        (getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager).showSoftInput(addr, InputMethodManager.SHOW_IMPLICIT)
    }

    private fun unfocusAddress() {
        (getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager).hideSoftInputFromWindow(addr.windowToken, 0)
        addr.clearFocus()
        root.requestFocus()
    }

    private fun addressFocus(focused: Boolean) {
        bottom.visibility = if (focused || keyboard) View.GONE else View.VISIBLE
        aiBtn.visibility = if (focused) View.GONE else View.VISIBLE
        if (focused) {
            val t = tab()
            val full = if (t == null || t.url.isEmpty()) "" else (Search.query(t.url) ?: t.url)
            addr.setText(full)
            addr.selectAll()
            suggestFor(full)
        } else {
            suggest?.let { content.removeView(it) }
            suggest = null
            updateBars()
        }
    }

    // ---- suggestions ----

    private fun suggestFor(text: String) {
        val seq = ++suggestSeq
        val t = text.trim()
        if (t.isEmpty()) {
            showSuggestions(emptyList(), emptyList())
            return
        }
        bg.execute {
            val h = hist.suggest(t, 4)
            ui.post { if (seq == suggestSeq) showSuggestions(h, emptyList()) }
            if (tab()?.private == true) return@execute
            net.execute {
                if (seq != suggestSeq) return@execute
                val g = Search.suggest(t)
                ui.post { if (seq == suggestSeq) showSuggestions(h, g) }
            }
        }
    }

    private fun showSuggestions(h: List<Entry>, g: List<String>) {
        if (!addr.hasFocus()) return
        val box = suggest ?: ScrollView(this).also {
            it.setBackgroundColor(pal.surface)
            content.addView(it, flp(MATCH, MATCH))
            suggest = it
        }
        box.removeAllViews()
        val list = LinearLayout(this)
        list.orientation = LinearLayout.VERTICAL
        list.setPadding(0, dp(6), 0, dp(6))
        for (e in h) list.addView(row(R.drawable.ic_history, e.title.ifEmpty { display(e.url) }, display(e.url)) { go(e.url) })
        for (s in g) list.addView(row(R.drawable.ic_search, s, "") { go(s) })
        if (h.isEmpty() && g.isEmpty() && addr.text.isEmpty()) {
            // modes to search with, while nothing is typed
            val f = Flow(this, dp(8))
            f.setPadding(dp(16), dp(10), dp(16), dp(10))
            for (m in Mode.values()) f.addView(chip(pal, m.label, modeIcon(m), m == set.mode) { set.mode = m; showSuggestions(h, g) })
            list.addView(f, lp(MATCH, WRAP))
        }
        box.addView(list, FrameLayout.LayoutParams(MATCH, WRAP))
    }

    private fun row(icon: Int, title: String, sub: String, onClick: () -> Unit): View {
        val r = LinearLayout(this)
        r.orientation = LinearLayout.HORIZONTAL
        r.gravity = Gravity.CENTER_VERTICAL
        r.setPadding(dp(18), dp(10), dp(18), dp(10))
        r.background = ripple(pal, null, rounded(Palette.WHITE, 0f))
        val i = ImageView(this)
        i.setImageResource(icon)
        i.imageTintList = android.content.res.ColorStateList.valueOf(pal.onSurfaceVariant)
        r.addView(i, lp(dp(20), dp(20)))
        val col = LinearLayout(this)
        col.orientation = LinearLayout.VERTICAL
        col.setPadding(dp(16), 0, 0, 0)
        val a = text(title, 15.5f, pal.onSurface)
        a.setSingleLine(true)
        a.ellipsize = TextUtils.TruncateAt.END
        col.addView(a)
        if (sub.isNotEmpty() && sub != title) {
            val b = text(sub, 12.5f, pal.onSurfaceVariant)
            b.setSingleLine(true)
            b.ellipsize = TextUtils.TruncateAt.END
            col.addView(b)
        }
        r.addView(col, lp(0, WRAP, 1f))
        r.setOnClickListener { onClick() }
        return r
    }

    private fun modeIcon(m: Mode) = when (m) {
        Mode.AI -> R.drawable.ic_sparkle
        Mode.WEB -> R.drawable.ic_globe
        Mode.IMAGES -> R.drawable.ic_image
        Mode.VIDEOS -> R.drawable.ic_video
        Mode.YOUTUBE -> R.drawable.ic_play
    }

    // ---- the new tab page ----

    private fun showNtp() {
        ntp?.let { content.removeView(it) }
        val t = tab()
        val sv = ScrollView(this)
        sv.isFillViewport = true
        sv.setBackgroundColor(pal.surface)
        val col = LinearLayout(this)
        col.orientation = LinearLayout.VERTICAL
        col.gravity = Gravity.CENTER_HORIZONTAL
        col.setPadding(dp(24), dp(56), dp(24), dp(24))
        val logo = LogoView(this, pal)
        col.addView(logo, lp(dp(64), dp(64)))
        val title = text(if (t?.private == true) "Private tab" else "Lite", 28f, pal.onSurface, bold = true)
        col.addView(title, lp(WRAP, WRAP).also { it.topMargin = dp(14) })
        val sub = text(if (t?.private == true) "Nothing you do here is kept in your history." else "Light on memory. Fast to Google and YouTube.", 14f, pal.onSurfaceVariant)
        sub.gravity = Gravity.CENTER
        col.addView(sub, lp(WRAP, WRAP).also { it.topMargin = dp(4) })

        // the search pill: it opens the address bar
        val pill = LinearLayout(this)
        pill.orientation = LinearLayout.HORIZONTAL
        pill.gravity = Gravity.CENTER_VERTICAL
        pill.setPadding(dp(18), 0, dp(18), 0)
        pill.background = ripple(pal, rounded(pal.field, dp(28).toFloat(), dp(2), pal.primary), rounded(Palette.WHITE, dp(28).toFloat()))
        pill.elevation = dp(3).toFloat()
        val si = ImageView(this)
        si.setImageResource(modeIcon(set.mode))
        si.imageTintList = android.content.res.ColorStateList.valueOf(pal.primary)
        pill.addView(si, lp(dp(20), dp(20)))
        val ph = text(if (set.mode == Mode.AI) "Ask AI Mode or type an address" else "Search or type an address", 16f, pal.faint)
        ph.setPadding(dp(12), 0, 0, 0)
        pill.addView(ph, lp(0, WRAP, 1f))
        pill.setOnClickListener { focusAddress() }
        col.addView(pill, lp(MATCH, dp(56)).also { it.topMargin = dp(28) })

        val chips = Flow(this, dp(8))
        for (m in Mode.values()) chips.addView(chip(pal, m.label, modeIcon(m), m == set.mode) { set.mode = m; showNtp() })
        col.addView(chips, lp(MATCH, WRAP).also { it.topMargin = dp(16) })

        val spacer = View(this)
        col.addView(spacer, lp(1, 0, 1f))
        val blocked = set.blockedTotal + blockedSession
        val foot = text(if (set.shields) "Lite Shields on · ${"%,d".format(blocked)} ads and trackers blocked" else "Lite Shields off", 12.5f, pal.onSurfaceVariant)
        foot.gravity = Gravity.CENTER
        col.addView(foot, lp(WRAP, WRAP).also { it.topMargin = dp(32) })
        sv.addView(col, FrameLayout.LayoutParams(MATCH, MATCH))
        content.addView(sv, flp(MATCH, MATCH))
        ntp = sv
    }

    // ---- the tab grid ----

    private fun openGrid() {
        closeSheet()
        unfocusAddress()
        grid?.let { content.removeView(it) }
        val wrap = LinearLayout(this)
        wrap.orientation = LinearLayout.VERTICAL
        wrap.setBackgroundColor(pal.frame)
        wrap.isClickable = true
        val head = LinearLayout(this)
        head.orientation = LinearLayout.HORIZONTAL
        head.gravity = Gravity.CENTER_VERTICAL
        head.setPadding(dp(18), dp(8), dp(12), dp(8))
        head.addView(text(if (tabs.size == 1) "1 tab" else "${tabs.size} tabs", 22f, pal.onSurface, bold = true), lp(0, WRAP, 1f))
        head.addView(iconButton(pal, R.drawable.ic_private, "New private tab") { closeGrid(); newTab("", true); focusAddress() }, lp(dp(48), dp(48)))
        head.addView(button(pal, "Done", true) { closeGrid() }, lp(WRAP, dp(40)).also { it.leftMargin = dp(6) })
        wrap.addView(head, lp(MATCH, WRAP))

        val sv = ScrollView(this)
        val list = LinearLayout(this)
        list.orientation = LinearLayout.VERTICAL
        list.setPadding(dp(12), dp(4), dp(12), dp(16))
        val cols = if (resources.configuration.screenWidthDp >= 600) 3 else 2
        var row: LinearLayout? = null
        for ((i, t) in tabs.withIndex()) {
            if (i % cols == 0) {
                row = LinearLayout(this)
                row.orientation = LinearLayout.HORIZONTAL
                list.addView(row, lp(MATCH, dp(180)))
            }
            row!!.addView(card(i, t), lp(0, MATCH, 1f).also { it.setMargins(dp(5), dp(5), dp(5), dp(5)) })
        }
        // keep the last row's cards the same width
        val rest = (cols - tabs.size % cols) % cols
        for (k in 0 until rest) row?.addView(View(this), lp(0, MATCH, 1f).also { it.setMargins(dp(5), dp(5), dp(5), dp(5)) })
        sv.addView(list)
        wrap.addView(sv, lp(MATCH, 0, 1f))
        content.addView(wrap, flp(MATCH, MATCH))
        grid = wrap
        tab()?.web?.visibility = View.GONE
    }

    private fun card(i: Int, t: Tab): View {
        val c = LinearLayout(this)
        c.orientation = LinearLayout.VERTICAL
        val selected = i == cur
        c.background = ripple(pal, rounded(pal.surface, dp(16).toFloat(), dp(if (selected) 2 else 1), if (selected) pal.primary else pal.outlineVariant),
            rounded(Palette.WHITE, dp(16).toFloat()))
        c.elevation = dp(2).toFloat()
        val head = LinearLayout(this)
        head.orientation = LinearLayout.HORIZONTAL
        head.gravity = Gravity.CENTER_VERTICAL
        head.setPadding(dp(12), 0, 0, 0)
        val name = text(when {
            t.title.isNotEmpty() -> t.title
            t.url.isNotEmpty() -> display(t.url)
            t.private -> "Private tab"
            else -> "New tab"
        }, 13f, pal.onSurface, bold = true)
        name.setSingleLine(true)
        name.ellipsize = TextUtils.TruncateAt.END
        head.addView(name, lp(0, WRAP, 1f))
        head.addView(iconButton(pal, R.drawable.ic_close, "Close tab") {
            closeTab(i)
            if (grid != null) openGrid()
        }, lp(dp(40), dp(40)))
        c.addView(head, lp(MATCH, dp(40)))
        val body = FrameLayout(this)
        body.background = rounded(pal.surfaceHigh, dp(12).toFloat())
        val host = hostOf(t.url)
        if (t.url.isEmpty() || Search.query(t.url) != null) {
            val ic = ImageView(this)
            ic.setImageResource(if (t.url.isEmpty()) (if (t.private) R.drawable.ic_private else R.drawable.ic_add) else R.drawable.ic_search)
            ic.imageTintList = android.content.res.ColorStateList.valueOf(pal.primary)
            body.addView(ic, flp(dp(32), dp(32), Gravity.CENTER))
        } else {
            val m = text(monogram(host), 22f, Palette.WHITE, bold = true)
            m.gravity = Gravity.CENTER
            m.background = rounded(siteColor(host), dp(13).toFloat())
            body.addView(m, flp(dp(46), dp(46), Gravity.CENTER).also { it.bottomMargin = dp(14) })
            val h = text(host.removePrefix("www."), 11.5f, pal.onSurfaceVariant)
            h.setSingleLine(true)
            h.ellipsize = TextUtils.TruncateAt.END
            body.addView(h, flp(WRAP, WRAP, Gravity.CENTER_HORIZONTAL or Gravity.BOTTOM).also { it.bottomMargin = dp(10) })
        }
        c.addView(body, lp(MATCH, 0, 1f).also { it.setMargins(dp(8), 0, dp(8), dp(8)) })
        c.setOnClickListener {
            closeGrid()
            selectTab(i)
        }
        return c
    }

    private fun closeGrid() {
        grid?.let { content.removeView(it) }
        grid = null
        show()
    }

    // ---- the menu ----

    private fun openSheet() {
        closeGrid()
        unfocusAddress()
        val scrim = FrameLayout(this)
        scrim.setBackgroundColor(pal.scrim)
        scrim.setOnClickListener { closeSheet() }
        val panel = LinearLayout(this)
        panel.orientation = LinearLayout.VERTICAL
        val r = dp(28).toFloat()
        val bgd = android.graphics.drawable.GradientDrawable()
        bgd.setColor(pal.surface)
        bgd.cornerRadii = floatArrayOf(r, r, r, r, 0f, 0f, 0f, 0f)
        panel.background = bgd
        panel.isClickable = true
        panel.setPadding(0, dp(10), 0, insetBottom)
        val handle = View(this)
        handle.background = rounded(pal.outline, dp(2).toFloat())
        panel.addView(handle, lp(dp(32), dp(4)).also { it.gravity = Gravity.CENTER_HORIZONTAL; it.bottomMargin = dp(6) })
        val sv = ScrollView(this)
        sv.addView(menuContent())
        panel.addView(sv, lp(MATCH, WRAP))
        val h = (resources.displayMetrics.heightPixels * 0.82f).toInt()
        scrim.addView(panel, flp(MATCH, WRAP, Gravity.BOTTOM))
        panel.layoutParams.height = WRAP
        sv.layoutParams = lp(MATCH, WRAP)
        panel.post { if (panel.height > h) panel.layoutParams = flp(MATCH, h, Gravity.BOTTOM) }
        root.addView(scrim, flp(MATCH, MATCH))
        sheet = scrim
    }

    private fun closeSheet() {
        sheet?.let { root.removeView(it) }
        sheet = null
    }

    private fun menuContent(): View {
        val col = LinearLayout(this)
        col.orientation = LinearLayout.VERTICAL
        col.setPadding(dp(20), dp(4), dp(20), dp(20))
        val t = tab()

        // quick actions
        val acts = LinearLayout(this)
        acts.orientation = LinearLayout.HORIZONTAL
        fun action(icon: Int, label: String, on: Boolean = true, f: () -> Unit) {
            val a = LinearLayout(this)
            a.orientation = LinearLayout.VERTICAL
            a.gravity = Gravity.CENTER
            a.background = ripple(pal, rounded(pal.surfaceHigh, dp(16).toFloat()), rounded(Palette.WHITE, dp(16).toFloat()))
            a.alpha = if (on) 1f else 0.4f
            val i = ImageView(this)
            i.setImageResource(icon)
            i.imageTintList = android.content.res.ColorStateList.valueOf(pal.primary)
            a.addView(i, lp(dp(22), dp(22)))
            val l = text(label, 12f, pal.onSurface, bold = true)
            l.gravity = Gravity.CENTER
            l.setSingleLine(true)
            a.addView(l, lp(WRAP, WRAP).also { it.topMargin = dp(6) })
            if (on) a.setOnClickListener { closeSheet(); f() }
            acts.addView(a, lp(0, dp(72), 1f).also { it.setMargins(dp(4), 0, dp(4), 0) })
        }
        val page = t != null && t.url.isNotEmpty()
        action(R.drawable.ic_private, "Private") { newTab("", true); focusAddress() }
        action(R.drawable.ic_reload, "Reload", page) { tab()?.web?.reload() }
        action(R.drawable.ic_share, "Share", page) {
            val s = Intent(Intent.ACTION_SEND)
            s.type = "text/plain"
            s.putExtra(Intent.EXTRA_TEXT, t!!.url)
            startActivity(Intent.createChooser(s, "Share"))
        }
        action(R.drawable.ic_desktop, if (set.desktop) "Mobile site" else "Desktop site", page) {
            set.desktop = !set.desktop
            for (o in tabs) o.web?.let { w -> w.settings.userAgentString = if (set.desktop) pages.desktopAgent(WebSettingsDefault.agent(this)) else null }
            tab()?.web?.reload()
        }
        col.addView(acts, lp(MATCH, WRAP).also { it.bottomMargin = dp(8) })

        // look
        col.addView(section("Look"))
        val sw = Flow(this, dp(10))
        for (p in Palette.all) {
            val v = object : View(this) {
                val paint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG)
                override fun onDraw(c: android.graphics.Canvas) {
                    val w = width.toFloat()
                    val o = android.graphics.RectF(dp(3).toFloat(), dp(3).toFloat(), w - dp(3), w - dp(3))
                    paint.style = android.graphics.Paint.Style.FILL
                    paint.color = p.swatch.getOrElse(1) { p.primary }
                    c.drawArc(o, 0f, 180f, true, paint)
                    paint.color = if (p.dark) p.surface else p.primary
                    c.drawArc(o, 180f, 180f, true, paint)
                    if (p.id == pal.id) {
                        paint.style = android.graphics.Paint.Style.STROKE
                        paint.strokeWidth = dp(2).toFloat()
                        paint.color = pal.onSurface
                        c.drawCircle(w / 2, w / 2, w / 2 - dp(1), paint)
                    }
                }
            }
            v.contentDescription = p.label
            v.setOnClickListener {
                set.theme = p.id
                pal = p
                closeSheet()
                buildUi()
            }
            sw.addView(v, ViewGroup.LayoutParams(dp(40), dp(40)))
        }
        col.addView(sw, lp(MATCH, WRAP).also { it.bottomMargin = dp(6) })

        // search
        col.addView(section("Search"))
        val modes = Flow(this, dp(8))
        for (m in Mode.values()) modes.addView(chip(pal, m.label, modeIcon(m), m == set.mode) { set.mode = m; closeSheet(); openSheet() })
        col.addView(modes, lp(MATCH, WRAP))
        col.addView(note("Google opens in the mode you pick. Type \"yt \" before words to search YouTube."))

        // shields
        col.addView(section("Lite Shields"))
        col.addView(toggle("Block ads and trackers", set.shields) { set.shields = it; pages.clearCache(); updateBars() })
        val host = t?.url?.let { hostOf(it).removePrefix("www.") } ?: ""
        if (host.isNotEmpty() && Search.query(t!!.url) == null) {
            col.addView(toggle("On for $host", host !in set.shieldOff) { on ->
                set.shieldOff = if (on) set.shieldOff - host else set.shieldOff + host
                pages.clearCache()
                tab()?.web?.reload()
            })
        }
        col.addView(toggle("Filter lists (EasyList, EasyPrivacy, uBlock)", set.lists) { set.lists = it; loadShields(refresh = true) })
        col.addView(toggle("Hide cookie notices", set.cookies) { set.cookies = it; loadShields(refresh = true) })
        col.addView(toggle("Clean links of tracking", set.cleanLinks) { set.cleanLinks = it })
        col.addView(toggle("HTTPS only", set.httpsOnly) { set.httpsOnly = it })
        col.addView(toggle("Fingerprinting protection", set.farble) { set.farble = it })
        col.addView(toggle("YouTube without ads", set.youtube) { set.youtube = it })
        col.addView(toggle("Lighter YouTube (H.264, no previews)", set.youtubeLight) { set.youtubeLight = it })
        val e = pages.shields
        val at = FilterLists.updatedAt(File(filesDir, "lists"))
        col.addView(note(if (e != null && e.rules > 0) "${"%,d".format(e.rules)} blocking rules and ${"%,d".format(e.hiding)} hiding rules" + (if (at > 0) ", updated " + ago(at) else "") + "."
            else "The filter lists download in the background; a built-in list blocks the commonest ads until then."))
        col.addView(button(pal, "Update filter lists", false) {
            File(filesDir, "lists").listFiles()?.forEach { it.setLastModified(0) }
            loadShields(refresh = true)
            Toast.makeText(this, "Updating the filter lists", Toast.LENGTH_SHORT).show()
        }, lp(WRAP, dp(40)).also { it.topMargin = dp(8) })

        // data
        col.addView(section("Data"))
        col.addView(button(pal, "Clear history", false) { hist.clear(); Toast.makeText(this, "History cleared", Toast.LENGTH_SHORT).show() }, lp(WRAP, dp(40)))
        col.addView(button(pal, "Clear cookies and site data", false) {
            AlertDialog.Builder(this).setMessage("Sign out of every site and delete what sites stored?")
                .setPositiveButton("Clear") { _, _ ->
                    CookieManager.getInstance().removeAllCookies(null)
                    WebStorage.getInstance().deleteAllData()
                    for (o in tabs) o.web?.clearCache(true)
                    Toast.makeText(this, "Cookies and site data cleared", Toast.LENGTH_SHORT).show()
                }.setNegativeButton("Cancel", null).show()
        }, lp(WRAP, dp(40)).also { it.topMargin = dp(8) })

        // about
        col.addView(section("About"))
        val wv = WebView.getCurrentWebViewPackage()?.versionName ?: ""
        col.addView(note("Lite 1.0 for Android · pages by Android System WebView $wv\nTulipan Labs (Cesar Jose Luis Torrecilla Gelvez) · PolyForm Noncommercial 1.0.0"))
        return col
    }

    private fun section(title: String): View {
        val t = text(title, 13f, pal.primary, bold = true)
        t.setPadding(0, dp(18), 0, dp(8))
        return t
    }

    private fun note(s: String): View {
        val t = text(s, 12.5f, pal.onSurfaceVariant)
        t.setPadding(0, dp(6), 0, 0)
        return t
    }

    private fun toggle(label: String, on: Boolean, f: (Boolean) -> Unit): View {
        val r = LinearLayout(this)
        r.orientation = LinearLayout.HORIZONTAL
        r.gravity = Gravity.CENTER_VERTICAL
        r.addView(text(label, 15f, pal.onSurface), lp(0, WRAP, 1f))
        val s = Switch(this)
        s.isChecked = on
        val states = arrayOf(intArrayOf(android.R.attr.state_checked), intArrayOf())
        s.thumbTintList = android.content.res.ColorStateList(states, intArrayOf(pal.primary, pal.surfaceHighest))
        s.trackTintList = android.content.res.ColorStateList(states, intArrayOf(pal.primaryContainer, pal.outline))
        s.setOnCheckedChangeListener { _, v -> f(v) }
        r.addView(s)
        r.setOnClickListener { s.toggle() }
        r.minimumHeight = dp(48)
        return r
    }

    private fun ago(t: Long): String {
        val m = (System.currentTimeMillis() - t) / 60000
        return when {
            m < 2 -> "just now"
            m < 60 -> "$m minutes ago"
            m < 48 * 60 -> "${m / 60} hours ago"
            else -> "${m / 1440} days ago"
        }
    }

    private fun shieldDialog() {
        val t = tab()
        if (t == null || t.url.isEmpty()) {
            openSheet()
            return
        }
        val host = hostOf(t.url).removePrefix("www.")
        val on = pages.shieldOn(t.url)
        val msg = if (on) "${t.blocked} ads and trackers blocked on this page." else "Lite Shields is off for $host."
        AlertDialog.Builder(this).setTitle("Lite Shields").setMessage(msg)
            .setPositiveButton(if (on) "Turn off for this site" else "Turn on for this site") { _, _ ->
                set.shieldOff = if (on) set.shieldOff + host else set.shieldOff - host
                pages.clearCache()
                t.web?.reload()
                updateBars()
            }
            .setNeutralButton("Settings") { _, _ -> openSheet() }
            .show()
    }

    // ---- page events ----

    override fun onUrl(t: Tab, url: String) {
        if (url.startsWith("about:")) return
        t.url = url
        if (t === tab()) {
            ntp?.let { if (t.web?.visibility == View.VISIBLE) { content.removeView(it); ntp = null } }
            updateBars()
        }
        if (!t.private) hist.add(url, t.title)
    }

    override fun onTitle(t: Tab, title: String) {
        if (title.startsWith("http") || title.isEmpty()) return
        t.title = title
        if (!t.private) hist.title(t.url, title)
    }

    override fun onProgress(t: Tab, progress: Int) {
        t.progress = progress
        if (t === tab()) {
            this.progress.progress = if (progress >= 100) 0f else progress / 100f
            if (progress >= 100) updateBars()
        }
    }

    override fun onBlocked(t: Tab) {
        t.blocked++
        blockedSession++
        if (t === tab()) {
            badge.visibility = View.VISIBLE
            badge.text = if (t.blocked > 999) "999+" else t.blocked.toString()
        }
    }

    override fun onNewTab(from: Tab, url: String, transport: Message?) {
        val t = Tab(nextId++, from.private)
        tabs.add(cur + 1, t)
        val w = pages.make(t)
        content.addView(w, 0, flp(MATCH, MATCH))
        t.url = url
        if (transport != null) {
            (transport.obj as WebView.WebViewTransport).webView = w
            transport.sendToTarget()
        } else if (url.isNotEmpty()) w.loadUrl(url)
        selectTab(cur + 1)
    }

    override fun onFullscreen(view: View?, done: WebChromeClient.CustomViewCallback?) {
        if (view != null) {
            full?.let { root.removeView(it) }
            full = view
            fullDone = done
            view.setBackgroundColor(Palette.BLACK)
            root.addView(view, flp(MATCH, MATCH))
            systemBars(false)
            requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_FULL_USER
            return
        }
        val v = full ?: return
        full = null
        root.removeView(v)
        fullDone?.onCustomViewHidden()
        fullDone = null
        systemBars(true)
        requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        root.requestApplyInsets()
    }

    override fun onCrashed(t: Tab) {
        Toast.makeText(this, "A page stopped working and was reloaded", Toast.LENGTH_SHORT).show()
        if (t === tab()) wake(t)
    }

    override fun onFileChooser(cb: ValueCallback<Array<Uri>>, params: WebChromeClient.FileChooserParams): Boolean {
        fileCb?.onReceiveValue(null)
        fileCb = cb
        return try {
            @Suppress("DEPRECATION")
            startActivityForResult(params.createIntent(), FILES)
            true
        } catch (e: Exception) {
            fileCb = null
            false
        }
    }

    override fun onLongPress(t: Tab, link: String, image: String) {
        val items = ArrayList<Pair<String, () -> Unit>>()
        if (link.isNotEmpty()) {
            items.add("Open in new tab" to { newTab(Links.clean(link), t.private, select = false); Toast.makeText(this, "Opened in a new tab", Toast.LENGTH_SHORT).show() })
            items.add("Open in private tab" to { newTab(Links.clean(link), true) })
            items.add("Copy link" to { copy(Links.clean(link)) })
            items.add("Share link" to {
                val s = Intent(Intent.ACTION_SEND)
                s.type = "text/plain"
                s.putExtra(Intent.EXTRA_TEXT, Links.clean(link))
                startActivity(Intent.createChooser(s, "Share"))
            })
        }
        if (image.isNotEmpty() && image.startsWith("http")) {
            items.add("Open image in new tab" to { newTab(image, t.private, select = false) })
            items.add("Copy image address" to { copy(image) })
        }
        if (items.isEmpty()) return
        AlertDialog.Builder(this).setTitle(display(link.ifEmpty { image }))
            .setItems(items.map { it.first }.toTypedArray()) { _, i -> items[i].second() }
            .show()
    }

    private fun copy(s: String) {
        (getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(ClipData.newPlainText("Link", s))
        if (Build.VERSION.SDK_INT < 33) Toast.makeText(this, "Copied", Toast.LENGTH_SHORT).show()
    }

    // ---- shields, intents, the session ----

    private fun loadShields(refresh: Boolean) {
        val ids = set.listIds()
        val dir = File(filesDir, "lists")
        bg.execute {
            val e = if (ids.isEmpty()) Shields() else FilterLists.load(dir, ids, refresh)
            ui.post {
                pages.shields = e
                pages.clearCache()
            }
        }
    }

    private fun handleIntent(i: Intent?): Boolean {
        if (i == null) return false
        when (i.action) {
            Intent.ACTION_VIEW -> {
                val u = i.dataString ?: return false
                newTab(Links.clean(u), false)
                return true
            }
            Intent.ACTION_WEB_SEARCH -> {
                val q = i.getStringExtra(SearchManager.QUERY) ?: return false
                newTab(Search.resolve(q, set.mode), false)
                return true
            }
            Intent.ACTION_SEND -> {
                val s = i.getStringExtra(Intent.EXTRA_TEXT) ?: return false
                val link = Regex("https?://\\S+").find(s)?.value
                newTab(if (link != null) Links.clean(link) else Search.resolve(s, set.mode), false)
                return true
            }
        }
        return false
    }

    private fun saveSession() {
        val keep = tabs.filter { !it.private && it.url.isNotEmpty() }
        set.session = keep.map { it.url }
        set.sessionIndex = keep.indexOf(tab()).coerceAtLeast(0)
    }

    private fun restoreSession() {
        val urls = set.session
        if (urls.isEmpty()) return
        for (u in urls) {
            val t = Tab(nextId++, false)
            t.url = u
            t.page = u
            tabs.add(t)
        }
        // only the current tab loads now; the others when they are opened
        selectTab(set.sessionIndex.coerceIn(0, tabs.size - 1))
    }

    companion object {
        private const val FILES = 7
    }
}

/** the WebView's own user agent, for switching back from the desktop site */
object WebSettingsDefault {
    fun agent(ctx: Context): String = android.webkit.WebSettings.getDefaultUserAgent(ctx)
}
