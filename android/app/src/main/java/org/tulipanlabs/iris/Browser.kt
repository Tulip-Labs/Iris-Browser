package org.tulipanlabs.iris

import android.Manifest
import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.View
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import java.util.UUID

/**
 * One tab: a page (whichever engine draws it) in its container's profile,
 * made when the tab first opens something, so a new or restored tab costs
 * nothing until you go to it.
 */
class Tab(val container: String?, url: String = "") {
    val id: String = UUID.randomUUID().toString()
    var url by mutableStateOf(url)
    var title by mutableStateOf("")
    var progress by mutableIntStateOf(0)
    var loading by mutableStateOf(false)
    var canBack by mutableStateOf(false)
    var canForward by mutableStateOf(false)
    var web by mutableStateOf<PageView?>(null)
    /** ads, trackers and pop-ups stopped on this page */
    var blocked by mutableIntStateOf(0)
    /** an address to open when the tab is next shown */
    var pending: String? = null
    /** the page's history, kept while the tab sleeps */
    var saved: Bundle? = null
    var lastShown = System.currentTimeMillis()
    var crashed by mutableStateOf(false)
    /** a pop-up whose first address is not checked yet: it stays hidden until then */
    var popupFrom: Tab? = null
    /** the page's address for the network thread (Compose state is read on the main thread) */
    @Volatile var top: String = url

    val isPrivate get() = container == Container.PRIVATE

    fun back() { web?.goBack() }
    fun forward() { web?.goForward() }
    fun reload() { web?.reload() }
    fun stop() { web?.stopLoading() }
}

/** a pop-up the page asked for and Iris stopped */
data class Blocked(val url: String, val from: Tab)

/** what a long press on a page landed on */
data class Pressed(val tab: Tab, val link: String?, val image: String?)

/**
 * The tabs and their pages, kept here so they outlive Compose's
 * recompositions and the activity. The page engine (System WebView or
 * Cefrium, by flavor) is behind Engine; the policy here (Shields, pop-ups,
 * the sandbox, sign-ins) is the same for both.
 */
class BrowserModel(app: Application) : AndroidViewModel(app), PageEvents, AudioController {
    val tabs = mutableStateListOf<Tab>()
    var current by mutableStateOf<Tab?>(null)
        private set
    var blocked by mutableStateOf<Blocked?>(null)
    var pressed by mutableStateOf<Pressed?>(null)
    /** a video in full screen: the engine hands Iris its view, and the bars step aside */
    var fullscreenView by mutableStateOf<View?>(null)
        private set
    val fullscreen get() = fullscreenView != null
    private var fullscreenExit: (() -> Unit)? = null
    /** a page's file field, answered by the activity's picker */
    var fileRequest by mutableStateOf<FileRequest?>(null)
    /** a page asking for the camera or microphone, answered by the activity */
    var mediaRequest by mutableStateOf<MediaRequest?>(null)
    /** the notification permission, asked the first time audio plays */
    var notificationRequest by mutableStateOf(false)
    /** the tabs whose pages are playing sound, latest first to last: the
     *  service keeps the latest one playing */
    private val playingTabs = ArrayDeque<Tab>()
    /** the tab whose page is playing sound, if any */
    val audioTab: Tab? get() = playingTabs.lastOrNull()
    /** sound is playing in a page right now */
    val audioPlaying: Boolean get() = playingTabs.isNotEmpty()
    /** the activity is behind Iris (its onPause ran, its onResume has not) */
    private var backgrounded = false
    /** the activity: pages are made in its context (dialogs, pickers), swapped when it is remade */
    var activity: Activity? = null
        set(v) { field = v; engine.onActivityChanged(v) }
    private val closed = ArrayDeque<Pair<String, String?>>()
    /** pop-ups made but not shown: each waits for its first address */
    private val held = mutableListOf<Tab>()
    /** a tab already open on Google AI Mode, waiting for the next new tab */
    private var spare: Tab? = null
    private val ui = Handler(Looper.getMainLooper())
    private val ctx: Context get() = getApplication()
    /** Iris is light: pages see prefers-color-scheme: light */
    var dark = false

    /** the page engine this build carries (WebView or Cefrium, by flavor) */
    val engine: Engine = EngineFactory.create()

    val containersWork: Boolean get() = engine.containersSupported

    init {
        Store.tabs.forEach { s ->
            val c = if (s.container == null || Store.container(s.container) != null) s.container else null
            tabs.add(Tab(c).also { it.pending = s.url; it.title = s.title; it.url = s.url })
        }
        if (tabs.isEmpty()) newTab() else select(tabs[Store.selected.coerceIn(0, tabs.size - 1)])
        Shields.changed = { synchronized(css) { css.clear() } }
        AudioPlayback.controller = this
    }

    fun newTab(url: String? = null, container: String? = null, after: Tab? = null, select: Boolean = true): Tab {
        // a plain new tab is Google AI Mode: the spare one, already loaded, when there is one
        val plain = url.isNullOrEmpty()
        val sp = spare?.takeIf { plain && container == null && it.web != null }
        val t = sp ?: Tab(container)
        if (sp != null) spare = null
        val i = after?.let { tabs.indexOf(it) } ?: -1
        if (i >= 0) tabs.add(i + 1, t) else tabs.add(t)
        val u = if (plain) Search.HOME else url!!
        if (sp == null) {
            t.url = u
            if (select) load(t, u) else t.pending = u
        }
        if (select || current == null) select(t)
        save()
        prepareSpare()
        return t
    }

    /** the next new tab, loaded in the background a moment after this one */
    private fun prepareSpare() {
        if (spare != null) return
        ui.postDelayed({
            if (spare != null || activity == null) return@postDelayed
            val s = Tab(null, Search.HOME)
            val w = web(s) ?: return@postDelayed
            spare = s
            w.loadUrl(Search.HOME)
        }, 1500)
    }

    fun select(t: Tab) {
        // the page that plays sound is not paused when you leave it for
        // another tab: that is how its sound survives the switch
        current?.let { it.lastShown = System.currentTimeMillis(); if (it.web !== audioTab?.web) it.web?.onPause(); it.web?.setPreraster(false) }
        current = t
        t.lastShown = System.currentTimeMillis()
        t.pending?.let { p -> if (activity != null) { t.pending = null; load(t, p) } }
        // a tab with nothing in it opens Google AI Mode
        if (t.web == null && t.pending == null && activity != null) load(t, t.url.ifEmpty { Search.HOME })
        t.web?.onResume()
        // the shown page is drawn ahead of the scroll, so it moves without gaps
        t.web?.setPreraster(true)
        Store.selected = tabs.indexOf(t)
    }

    /** the activity is here: the shown tab opens what it was waiting for */
    fun attached(a: Activity) {
        activity = a
        current?.let { t ->
            t.pending?.let { p -> t.pending = null; load(t, p) }
            if (t.web == null) load(t, t.url.ifEmpty { Search.HOME })
        }
        prepareSpare()
    }

    /** Closing a tab never closes Iris: the one beside it takes its place,
     *  and closing the last one leaves a fresh tab. */
    fun close(t: Tab) {
        val i = tabs.indexOf(t)
        if (i < 0) return
        if (t.url.isNotEmpty() && !t.isPrivate) closed.addLast(t.url to t.container)
        // the page that played is gone: nothing is left to keep playing
        if (playingTabs.remove(t) && playingTabs.isEmpty()) AudioPlayback.stop(ctx)
        tabs.removeAt(i)
        destroy(t)
        if (current === t) {
            current = null
            if (tabs.isEmpty()) newTab() else select(tabs[minOf(i, tabs.size - 1)])
        }
        if (t.isPrivate && tabs.none { it.isPrivate }) clearPrivate()
        save()
    }

    fun reopenClosed() {
        val (u, c) = closed.removeLastOrNull() ?: return
        newTab(u, c)
    }

    fun go(text: String) {
        val u = Search.resolve(text)
        if (u.isEmpty()) return
        val t = current ?: newTab()
        load(t, u)
    }

    fun load(t: Tab, url: String) {
        // a site Iris does not trust opens in the sandbox, and the tab stays as it was
        if (Search.untrusted(url)) {
            activity?.let { SandboxActivity.open(it, url) } ?: SandboxActivity.open(ctx, url)
            if (t.web == null && t.url == url) { t.url = Search.HOME; load(t, Search.HOME) }
            return
        }
        t.url = url
        t.top = url
        t.crashed = false
        val w = web(t) ?: run { t.pending = url; return }
        val s = t.saved
        if (s != null) {
            t.saved = null
            val restored = runCatching { w.restoreState(s) }.getOrDefault(false)
            if (!restored) w.loadUrl(url)
        } else {
            w.loadUrl(url)
        }
        save()
    }

    /** home: Google AI Mode, in this tab */
    fun home(t: Tab) = load(t, Search.HOME)

    private fun destroy(t: Tab) {
        t.web?.let { w ->
            runCatching { w.stopLoading() }
            w.destroy()
        }
        t.web = null
    }

    // ---- profiles: containers and private tabs ----

    /** the private tabs' profile is wiped when the last one closes */
    private fun clearPrivate() {
        engine.clearPrivateData()
    }

    /** a container's tabs close, and its profile and everything its sites kept go */
    fun removeContainer(id: String) {
        tabs.filter { it.container == id }.forEach(::close)
        engine.deleteProfile("c-$id")
    }

    fun shieldsFor(url: String) = Shields.onFor(url)

    fun toggleSiteShields(t: Tab) {
        val h = Search.host(t.url) ?: return
        val site = Search.site(h)
        val off = Store.shieldsOff.toMutableSet()
        if (!off.add(site)) off.remove(site)
        Store.shieldsOff = off
        synchronized(css) { css.clear() }
        t.reload()
    }

    fun shieldsChanged() {
        synchronized(css) { css.clear() }
        current?.reload()
    }

    // ---- the engine ----

    private val youtube by lazy { runCatching { ctx.assets.open("js/youtube.js").bufferedReader().use { it.readText() } }.getOrDefault("") }
    private val aiGlass by lazy { runCatching { ctx.assets.open("js/aimode.js").bufferedReader().use { it.readText() } }.getOrDefault("") }

    /** scripts that run before a page's own: YouTube without ads, the glass on Google AI Mode */
    val documentScripts: List<DocumentScript> by lazy {
        buildList {
            if (youtube.isNotBlank()) add(DocumentScript(youtube, setOf("https://*.youtube.com", "https://youtube.com")))
            if (aiGlass.isNotBlank()) add(DocumentScript(aiGlass, setOf("https://www.google.com", "https://google.com")))
        }
    }

    private val audioReport by lazy { runCatching { ctx.assets.open("js/audio.js").bufferedReader().use { it.readText() } }.getOrDefault("") }
    private val audioVisible by lazy { runCatching { ctx.assets.open("js/audio-visible.js").bufferedReader().use { it.readText() } }.getOrDefault("") }

    /** the audio scripts, in the page's own world: the reporter on every
     *  page (it only listens), the visibility one only while background
     *  audio is on (it is what stops YouTube pausing on the page hiding) */
    private fun injectAudio(page: PageView) {
        if (audioReport.isNotBlank()) runCatching { page.evaluateJavascript(audioReport) }
        if (Store.backgroundAudio && audioVisible.isNotBlank()) runCatching { page.evaluateJavascript(audioVisible) }
    }

    /** the setting changed: pages opened from now on carry the visibility
     *  script, and the shown page gets it at once, so no reload is needed.
     *  Turning it off stops nothing that plays now; the next time Iris
     *  leaves the screen the page pauses as it always has */
    fun applyBackgroundAudio(on: Boolean) {
        Store.backgroundAudio = on
        // the shown page gets both scripts at once: the visibility one, and
        // the reporter again, so a page already playing says so afresh
        if (on) current?.web?.let { injectAudio(it) }
        else {
            playingTabs.clear()
            AudioPlayback.stop(ctx)
        }
    }

    /** the tab's page, made on first use (null until the activity is here) */
    fun web(t: Tab): PageView? {
        t.web?.let { return it }
        val p = engine.createPage(t, this) ?: return null
        t.web = p
        if (t !== current && t.popupFrom == null) p.onPause()
        return p
    }

    // ---- what the pages report (PageEvents) ----

    override fun onPageStarted(t: Tab, url: String) {
        // the page that played went somewhere else: its sound is gone with it
        if (playingTabs.remove(t) && playingTabs.isEmpty()) AudioPlayback.stop(ctx)
        // a pop-up that went straight to its address (no override asked):
        // checked here instead
        t.popupFrom?.let { from ->
            if (url == "about:blank" || url.isEmpty()) return
            t.popupFrom = null
            if (!popupAllowed(from, url)) {
                t.web?.stopLoading()
                ui.post { denyPopup(t, from, url) }
                return
            }
            ui.post { approvePopup(t, from) }
        }
        t.url = url
        t.top = url
        t.blocked = 0
        t.loading = true
        t.progress = 5
        t.canBack = t.web?.canGoBack() == true
        t.canForward = t.web?.canGoForward() == true
    }

    override fun onPageCommitVisible(t: Tab, url: String) {
        t.web?.let { hide(it, url); injectAudio(it) }
        // where the engine cannot add the glass before the page, it comes now
        if (Search.isAIMode(url) && !engine.supportsDocumentStartScript && aiGlass.isNotBlank()) {
            t.web?.let { runCatching { it.evaluateJavascript(aiGlass) } }
        }
    }

    override fun onPageFinished(t: Tab, url: String) {
        t.loading = false
        t.progress = 100
        t.url = url
        t.top = url
        t.canBack = t.web?.canGoBack() == true
        t.canForward = t.web?.canGoForward() == true
        t.web?.let { hide(it, url); injectAudio(it) }
        if (!t.isPrivate && url.startsWith("http")) Store.visit(url, t.title)
        save()
    }

    override fun onProgress(t: Tab, progress: Int) {
        t.progress = progress
        t.loading = progress < 100
    }

    override fun onTitle(t: Tab, title: String) {
        t.title = title
    }

    override fun onUrlChanged(t: Tab, url: String) {
        t.url = url
        t.top = url
        t.canBack = t.web?.canGoBack() == true
        t.canForward = t.web?.canGoForward() == true
    }

    /** Iris Shields: the engine asks before every request, on its network
     *  thread; what is stopped never leaves the phone */
    override fun shouldBlockRequest(t: Tab, url: String, kind: Int, mainFrame: Boolean): Boolean {
        if (mainFrame) return false
        if (!Shields.core.blocks(url, t.top, kind, false)) return false
        onBlocked(t)
        return true
    }

    override fun onBlocked(t: Tab) {
        ui.post { t.blocked++ }
    }

    override fun shouldOverrideNavigation(t: Tab, url: String, mainFrame: Boolean, hasGesture: Boolean, isRedirect: Boolean, tappedLinkHost: String?): Boolean {
        val us = url
        // a pop-up's first address decides whether it may stay, before it is shown
        t.popupFrom?.let { from ->
            // sign-in windows often open empty first, then get their address
            if (!mainFrame || us == "about:blank") return false
            t.popupFrom = null
            if (!popupAllowed(from, us)) {
                ui.post { denyPopup(t, from, us) }
                return true
            }
            ui.post { approvePopup(t, from) }
        }
        val scheme = runCatching { Uri.parse(us).scheme?.lowercase() }.getOrNull()
        if (mainFrame) {
            // a Google result: straight to it, without Google's redirect
            Search.unwrapRedirect(us)?.let { target -> ui.post { load(t, target) }; return true }
            // a site Iris does not trust: the sandbox, without asking
            if ((scheme == "http" || scheme == "https") && Search.untrusted(us)) {
                activity?.let { SandboxActivity.open(it, us) }
                return true
            }
        }
        if (scheme == "http" || scheme == "https") {
            // ads that take the page itself away: a redirect, or a script
            // sending the tab to an ad without a tap on a link to it
            if (mainFrame && t.url.isNotEmpty() && isAd(t, us)) {
                val tapped = hasGesture && tappedLinkHost == Search.host(us)
                if (!tapped || isRedirect) {
                    ui.post { t.blocked++ }
                    return true
                }
            }
            return false
        }
        if (scheme == "about" || scheme == "data" || scheme == "blob") return false
        // intent:, mailto:, tel: and other apps, only on a tap, so a page
        // cannot open apps by itself
        if (!hasGesture) return true
        try {
            val i = if (scheme == "intent") Intent.parseUri(us, Intent.URI_INTENT_SCHEME) else Intent(Intent.ACTION_VIEW, Uri.parse(us))
            i.addCategory(Intent.CATEGORY_BROWSABLE)
            i.component = null
            i.selector = null
            // an intent: link may not grant access to Iris's own files
            i.flags = i.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION).inv()
            i.clipData = null
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            ctx.startActivity(i)
        } catch (e: Exception) {
            // an intent: link with a web fallback opens that instead
            if (scheme == "intent") {
                Regex("S\\.browser_fallback_url=([^;]+)").find(us)?.groupValues?.get(1)?.let { fb ->
                    val f = Uri.decode(fb)
                    if (f.startsWith("http")) ui.post { load(t, f) }
                }
            }
        }
        return true
    }

    // a certificate that fails: that site opens in the sandbox, without asking
    override fun onSslError(t: Tab, url: String) {
        if (url == t.top || Search.host(url) == Search.host(t.top)) {
            activity?.let { SandboxActivity.open(it, url, cert = true) }
            ui.post { if (t.web?.canGoBack() == true) t.web?.goBack() else load(t, Search.HOME) }
        }
    }

    override fun onRendererGone(t: Tab) {
        // the page's process ended (memory or a crash): the tab gets a
        // fresh page and opens its address again when shown
        destroy(t)
        t.pending = t.url.ifEmpty { null }
        t.crashed = true
        if (t === current) t.pending?.let { p -> t.pending = null; load(t, p) }
    }

    override fun onFileChooser(t: Tab, request: FileRequest) {
        fileRequest?.answer(null)
        fileRequest = request
    }

    override fun onMediaRequest(t: Tab, request: MediaRequest) {
        mediaRequest = request
    }

    override fun onLongPress(t: Tab, link: String?, image: String?) {
        pressed = Pressed(t, link, image)
    }

    /** a page started or stopped playing sound (its own report, by console) */
    override fun onAudioState(t: Tab, playing: Boolean) {
        if (!Store.backgroundAudio) return
        if (playing) {
            playingTabs.remove(t)
            playingTabs.addLast(t)
            if (playingTabs.size == 1) {
                requestNotificationPermission()
                // already behind Iris (a page that started by itself): the
                // service starts best-effort — Android 12 and newer may
                // refuse a start from the background
                if (backgrounded) AudioPlayback.start(ctx)
            }
        } else {
            playingTabs.remove(t)
            if (playingTabs.isEmpty()) AudioPlayback.stop(ctx)
        }
    }

    /** the notification permission, asked once, the first time audio plays:
     *  never at launch, and never again after an answer. The service starts
     *  either way — a media notification shows even when it is off */
    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT < 33 || Store.askedNotifications) return
        Store.askedNotifications = true
        if (activity?.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) return
        notificationRequest = true
    }

    /** the activity leaves the screen: the page that plays keeps going, and
     *  every other shown page pauses as it always has */
    fun enterBackground() {
        backgrounded = true
        // a page the console report missed still counts when its engine
        // knows it is playing (Cefrium asks its browser)
        if (audioTab == null) {
            current?.takeIf { engine.isPlayingAudio(it) }?.let { playingTabs.addLast(it) }
        }
        if (Store.backgroundAudio && audioPlaying) AudioPlayback.start(ctx)
        val playing = audioTab?.web
        current?.web?.let { if (it !== playing) it.onPause() }
    }

    /** the activity is in front again */
    fun leaveBackground() {
        backgrounded = false
    }

    override fun newHeldTab(from: Tab): Tab? {
        val nt = Tab(from.container)
        nt.popupFrom = from
        held.add(nt)
        return nt
    }

    /** a held pop-up that could not be made (no activity): it goes, quietly */
    fun dropHeldTab(p: Tab) {
        held.remove(p)
    }

    /** a held pop-up went somewhere allowed: it becomes a tab beside its page */
    override fun approvePopup(p: Tab, from: Tab) {
        if (!held.remove(p)) return
        val i = tabs.indexOf(from)
        if (i >= 0) tabs.add(i + 1, p) else tabs.add(p)
        select(p)
        save()
    }

    /** a held pop-up went to an ad, or elsewhere: it goes, never shown */
    override fun denyPopup(p: Tab, from: Tab, url: String?) {
        if (!held.remove(p)) return
        destroy(p)
        from.blocked++
        // not an ad, just another site: the notice offers to open it
        if (url != null && url.startsWith("http") && !isAd(from, url)) blocked = Blocked(url, from)
    }

    override fun schedulePopupTimeout(p: Tab, from: Tab) {
        // it went nowhere: the pop-up goes
        ui.postDelayed({ if (p.popupFrom != null) { p.popupFrom = null; denyPopup(p, from, null) } }, 8000)
    }

    override fun closeWindow(page: PageView) {
        held.firstOrNull { it.web === page }?.let { p -> held.remove(p); destroy(p); return }
        tabs.firstOrNull { it.web === page }?.let(::close)
    }

    override fun onFullscreen(t: Tab, view: View?, exit: () -> Unit) {
        fullscreenView = view
        fullscreenExit = if (view != null) exit else null
    }

    override fun onDownload(t: Tab, url: String, agent: String?, disposition: String?, mime: String?, length: Long, cookies: String?, suggested: String?) {
        Downloads.fetch(ctx, url, agent, disposition, mime, length, cookies, t.url, suggested)
    }

    /** the style sheet hiding what ads leave on each site, kept for a few sites */
    private val css = object : LinkedHashMap<String, String>(32, 0.75f, true) {
        override fun removeEldestEntry(e: MutableMap.MutableEntry<String, String>?) = size > 24
    }

    private fun hide(page: PageView, url: String) {
        if (!url.startsWith("http")) return
        val host = hostOf(url)
        val sheet = synchronized(css) { css[host] ?: Shields.core.hidingCSS(url).also { css[host] = it } }
        if (sheet.isEmpty()) return
        val js = "(() => { const add = () => { let s = document.getElementById('iris-shields'); if (!s) { s = document.createElement('style'); " +
            "s.id = 'iris-shields'; (document.head || document.documentElement).appendChild(s); } if (!s.textContent) s.textContent = " +
            org.json.JSONObject.quote(sheet) + "; }; if (document.documentElement) add(); else document.addEventListener('DOMContentLoaded', add); })();"
        runCatching { page.evaluateJavascript(js) }
    }

    /** whether going to `url` in the page `from` is an ad or tracker (the domain list, then the lists' rules) */
    internal fun isAd(from: Tab, url: String): Boolean {
        if (!url.startsWith("http") || !Shields.onFor(from.top)) return false
        val host = Search.host(url) ?: return false
        if (ShieldCore.never(host)) return false
        if (Shields.isBlocked(host)) return true
        return Shields.core.blocks(url, from.top.ifEmpty { url }, Kind.SUBDOCUMENT, false)
    }

    /** a pop-up may open as a tab: the same site, or a sign-in, and never an ad */
    override fun popupAllowed(from: Tab, url: String): Boolean {
        val host = Search.host(url) ?: return false
        if (isAd(from, url)) return false
        val site = Search.host(from.url)?.let { Search.site(it) }
        return Search.site(host) == site || Search.isSignIn(host)
    }

    fun exitFullscreen() {
        fullscreenExit?.invoke()
        fullscreenView = null
        fullscreenExit = null
    }

    fun save() {
        Store.tabs = tabs.filter { !it.isPrivate && (it.pending ?: it.url).isNotEmpty() }
            .map { SavedTab(it.pending ?: it.url, it.title, it.container) }
        current?.let { Store.selected = tabs.indexOf(it) }
    }

    // ---- the service's side: the page that plays, driven by its controls ----

    override val playing: Boolean get() = audioPlaying
    override val title: String get() = audioTab?.title ?: ""
    override val host: String get() = audioTab?.url?.let { Search.host(it) } ?: ""

    override fun play() {
        audioTab?.web?.let {
            runCatching { it.evaluateJavascript("document.querySelectorAll('audio,video').forEach(m=>{const p=m.play();if(p&&p.catch)p.catch(()=>{})})") }
        }
    }

    override fun pause() {
        audioTab?.web?.let {
            runCatching { it.evaluateJavascript("document.querySelectorAll('audio,video').forEach(m=>m.pause())") }
        }
    }

    override fun stop() {
        pause()
        playingTabs.clear()
        AudioPlayback.stop(ctx)
    }

    override fun onCleared() {
        AudioPlayback.controller = null
        AudioPlayback.stop(ctx)
        save()
        tabs.forEach(::destroy)
        held.forEach(::destroy)
        spare?.let(::destroy)
    }
}
