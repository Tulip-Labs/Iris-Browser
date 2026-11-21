package org.tulipanlabs.iris

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import org.mozilla.geckoview.AllowOrDeny
import org.mozilla.geckoview.GeckoResult
import org.mozilla.geckoview.GeckoSession
import org.mozilla.geckoview.GeckoSession.NavigationDelegate.LoadRequest
import org.mozilla.geckoview.GeckoSessionSettings
import org.mozilla.geckoview.WebResponse
import java.util.UUID

/**
 * One tab: a GeckoSession in its container (contextId keeps cookies,
 * storage, cache and IndexedDB apart), made when the tab first opens
 * something, so a new or restored tab costs nothing until you go to it.
 */
class Tab(val container: String?, url: String = "") {
    val id: String = UUID.randomUUID().toString()
    var url by mutableStateOf(url)
    var title by mutableStateOf("")
    var progress by mutableIntStateOf(0)
    var loading by mutableStateOf(false)
    var canBack by mutableStateOf(false)
    var canForward by mutableStateOf(false)
    var session by mutableStateOf<GeckoSession?>(null)
    /** an address to open when the tab is first shown */
    var pending: String? = null

    val isPrivate get() = container == Container.PRIVATE
}

/** a pop-up the page asked for and Iris stopped */
data class Blocked(val url: String, val from: Tab)


/**
 * The tabs and their sessions, kept here so they outlive Compose's
 * recompositions and the activity's configuration changes.
 */
class BrowserModel(app: Application) : AndroidViewModel(app) {
    private val runtime = (app as IrisApp).runtime
    val tabs = mutableStateListOf<Tab>()
    var current by mutableStateOf<Tab?>(null)
        private set
    var blocked by mutableStateOf<Blocked?>(null)
    var prompt by mutableStateOf<Prompt?>(null)
    var fullscreen by mutableStateOf(false)
    var contextMenu by mutableStateOf<Pair<Tab, GeckoSession.ContentDelegate.ContextElement>?>(null)
    private val closed = ArrayDeque<Pair<String, String?>>()

    init {
        val saved = Store.tabs
        saved.forEach { s ->
            val c = if (s.container == null || Store.container(s.container) != null) s.container else null
            tabs.add(Tab(c).also { it.pending = s.url; it.title = s.title; it.url = s.url })
        }
        if (tabs.isEmpty()) newTab() else select(tabs[Store.selected.coerceIn(0, tabs.size - 1)])
    }

    fun newTab(url: String? = null, container: String? = null, after: Tab? = null, select: Boolean = true): Tab {
        val t = Tab(container)
        val i = after?.let { tabs.indexOf(it) } ?: -1
        if (i >= 0) tabs.add(i + 1, t) else tabs.add(t)
        if (!url.isNullOrEmpty()) {
            if (select) load(t, url) else t.pending = url
            t.url = url
        }
        if (select || current == null) select(t)
        save()
        return t
    }

    fun select(t: Tab) {
        current?.session?.setActive(false)
        current = t
        t.pending?.let { p -> t.pending = null; load(t, p) }
        t.session?.setActive(true)
        Store.selected = tabs.indexOf(t)
    }

    /** Closing a tab never closes Iris: the one next to it takes its place,
     *  and closing the last one leaves a fresh tab. */
    fun close(t: Tab) {
        val i = tabs.indexOf(t)
        if (i < 0) return
        if (t.url.isNotEmpty() && !t.isPrivate) closed.addLast(t.url to t.container)
        tabs.removeAt(i)
        t.session?.close()
        t.session = null
        if (current === t) {
            current = null
            if (tabs.isEmpty()) newTab() else select(tabs[minOf(i, tabs.size - 1)])
        }
        save()
    }

    /** back to the new-tab page in this tab */
    fun home(t: Tab) {
        t.session?.close()
        t.session = null
        t.url = ""
        t.title = ""
        t.canBack = false
        t.canForward = false
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
        t.url = url
        session(t).loadUri(url)
        save()
    }

    /** the tab's session, made on first use (a pop-up's is left for
     *  GeckoView to open) */
    fun session(t: Tab, open: Boolean = true): GeckoSession {
        t.session?.let { return it }
        val settings = GeckoSessionSettings.Builder()
            .usePrivateMode(t.isPrivate)
            .useTrackingProtection(shieldsFor(t.url))
            .allowJavascript(true)
        // each container its own world
        t.container?.takeIf { it != Container.PRIVATE }?.let { settings.contextId(it) }
        val s = GeckoSession(settings.build())
        wire(t, s)
        if (open) s.open(runtime)
        t.session = s
        if (t === current) s.setActive(true)
        return s
    }

    fun shieldsFor(url: String): Boolean {
        if (!Store.shields) return false
        val h = Search.host(url) ?: return true
        return Search.site(h) !in Store.shieldsOff
    }

    fun toggleSiteShields(t: Tab) {
        val h = Search.host(t.url) ?: return
        val site = Search.site(h)
        val off = Store.shieldsOff.toMutableSet()
        if (!off.add(site)) off.remove(site)
        Store.shieldsOff = off
        t.session?.settings?.useTrackingProtection = shieldsFor(t.url)
        t.session?.reload()
    }

    private fun wire(t: Tab, s: GeckoSession) {
        s.navigationDelegate = object : GeckoSession.NavigationDelegate {
            override fun onLocationChange(session: GeckoSession, url: String?, perms: MutableList<GeckoSession.PermissionDelegate.ContentPermission>, hasUserGesture: Boolean) {
                t.url = url ?: ""
                session.settings.useTrackingProtection = shieldsFor(t.url)
                save()
            }
            override fun onCanGoBack(session: GeckoSession, canGoBack: Boolean) { t.canBack = canGoBack }
            override fun onCanGoForward(session: GeckoSession, canGoForward: Boolean) { t.canForward = canGoForward }

            // pop-ups: only when you tapped, and to the same site or a
            // sign-in; anything else is stopped (ads open no tabs)
            override fun onLoadRequest(session: GeckoSession, request: LoadRequest): GeckoResult<AllowOrDeny>? {
                if (request.target != GeckoSession.NavigationDelegate.TARGET_WINDOW_NEW) return null
                val host = Search.host(request.uri) ?: return GeckoResult.deny()
                val from = Search.host(t.url)?.let { Search.site(it) }
                val ok = request.hasUserGesture && (Search.site(host) == from || Search.isSignIn(host))
                if (ok) return null
                if (request.hasUserGesture) blocked = Blocked(request.uri, t)
                return GeckoResult.deny()
            }

            override fun onNewSession(session: GeckoSession, uri: String): GeckoResult<GeckoSession>? {
                val nt = Tab(t.container)
                val i = tabs.indexOf(t)
                tabs.add(if (i >= 0) i + 1 else tabs.size, nt)
                val ns = session(nt, open = false)
                nt.url = uri
                select(nt)
                return GeckoResult.fromValue(ns)
            }
        }
        s.progressDelegate = object : GeckoSession.ProgressDelegate {
            override fun onPageStart(session: GeckoSession, url: String) { t.loading = true; t.progress = 5 }
            override fun onPageStop(session: GeckoSession, success: Boolean) {
                t.loading = false
                t.progress = 100
                if (success && !t.isPrivate) Store.visit(t.url, t.title)
            }
            override fun onProgressChange(session: GeckoSession, progress: Int) { t.progress = progress }
        }
        s.contentDelegate = object : GeckoSession.ContentDelegate {
            override fun onTitleChange(session: GeckoSession, title: String?) { t.title = title ?: "" }
            override fun onCloseRequest(session: GeckoSession) { close(t) }
            override fun onFullScreen(session: GeckoSession, fullScreen: Boolean) { fullscreen = fullScreen }
            override fun onExternalResponse(session: GeckoSession, response: WebResponse) {
                Downloads.save(getApplication<Application>(), response, t.isPrivate)
            }
            override fun onContextMenu(session: GeckoSession, screenX: Int, screenY: Int, element: GeckoSession.ContentDelegate.ContextElement) {
                contextMenu = t to element
            }
            override fun onCrash(session: GeckoSession) {
                t.session = null
                if (t === current) t.url.takeIf { it.isNotEmpty() }?.let { load(t, it) }
            }
            override fun onKill(session: GeckoSession) {
                t.session = null
                t.pending = t.url.ifEmpty { null }
            }
        }
        s.promptDelegate = Prompts.delegate(this)
    }

    fun save() {
        Store.tabs = tabs.filter { !it.isPrivate && (it.pending ?: it.url).isNotEmpty() }
            .map { SavedTab(it.pending ?: it.url, it.title, it.container) }
        current?.let { Store.selected = tabs.indexOf(it) }
    }

    override fun onCleared() {
        save()
        tabs.forEach { it.session?.close() }
    }
}
