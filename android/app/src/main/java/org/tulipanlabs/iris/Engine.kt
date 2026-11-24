package org.tulipanlabs.iris

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.View

/**
 * Iris draws its pages with one of two engines, and the rest of the app
 * does not know which: the webview flavor uses Android System WebView
 * (Chromium, kept up to date by the phone), the cefrium flavor carries its
 * own Chromium (CEF, through Cefrium), the same engine on every phone.
 * Each flavor brings the engine that fits it (src/webview, src/cefrium);
 * the model talks to the page only through this file.
 */

/** what a page asks for: the camera, the microphone, or protected video */
enum class PagePermission { CAMERA, MICROPHONE, PROTECTED_MEDIA }

/** a page's file field, answered by the activity's picker */
class FileRequest(
    /** the picker's intent, made by the engine (its own chooser knows the field) */
    val createIntent: () -> Intent?,
    /** the picker's answer, read back by the engine */
    val parseResult: (resultCode: Int, data: Intent?) -> Array<Uri>?,
    /** the answer back to the page (null cancels it) */
    val answer: (Array<Uri>?) -> Unit,
)

/** a page asking for the camera or microphone, answered by the activity */
class MediaRequest(
    val resources: List<PagePermission>,
    val grant: (List<PagePermission>) -> Unit,
    val deny: () -> Unit,
)

/** one page, whichever engine draws it */
interface PageView {
    /** the view the page is drawn into */
    val view: View
    fun loadUrl(url: String)
    fun goBack()
    fun goForward()
    fun reload()
    fun stopLoading()
    fun canGoBack(): Boolean
    fun canGoForward(): Boolean
    fun onPause()
    fun onResume()
    /** runs a script in the page, with no answer (the hiding style sheet, the glass) */
    fun evaluateJavascript(script: String)
    /** the page's history, kept while the tab sleeps (null when there is none) */
    fun saveState(): Bundle?
    /** puts saved history back; false when there was none to put back */
    fun restoreState(state: Bundle): Boolean
    /** the shown page is drawn ahead of the scroll, so it moves without gaps */
    fun setPreraster(enabled: Boolean)
    /** the page is gone: its view leaves its parent, its engine is closed */
    fun destroy()
}

/**
 * What the model does when a page reports something. The engines call
 * these; the policy (Shields, pop-ups, the sandbox, sign-ins) lives in the
 * model alone, so both engines behave the same.
 */
interface PageEvents {
    fun onPageStarted(t: Tab, url: String)
    fun onPageCommitVisible(t: Tab, url: String)
    fun onPageFinished(t: Tab, url: String)
    fun onProgress(t: Tab, progress: Int)
    fun onTitle(t: Tab, title: String)
    fun onUrlChanged(t: Tab, url: String)
    /** a request the page is about to make: true stops it. Runs on a network thread. */
    fun shouldBlockRequest(t: Tab, url: String, kind: Int, mainFrame: Boolean): Boolean
    /**
     * A navigation the page is about to make: true means Iris handled it (or
     * stopped it), so the engine must not. `tappedLinkHost` is the host of
     * the link under the last tap, when the engine knows it (WebView); null
     * when it cannot tell (Cefrium), so a tap on an ad is stopped rather
     * than trusted.
     */
    fun shouldOverrideNavigation(t: Tab, url: String, mainFrame: Boolean, hasGesture: Boolean, isRedirect: Boolean, tappedLinkHost: String?): Boolean
    /** a certificate that failed: the engine has already refused it */
    fun onSslError(t: Tab, url: String)
    /** the page's process ended (memory or a crash) */
    fun onRendererGone(t: Tab)
    fun onFileChooser(t: Tab, request: FileRequest)
    fun onMediaRequest(t: Tab, request: MediaRequest)
    fun onLongPress(t: Tab, link: String?, image: String?)
    /** a page started or stopped playing sound (its own report, by console) */
    fun onAudioState(t: Tab, playing: Boolean)
    /** a page opened a window: the held tab for it, or null when it may not open */
    fun newHeldTab(from: Tab): Tab?
    /** a held pop-up went somewhere allowed: it becomes a tab beside its page */
    fun approvePopup(p: Tab, from: Tab)
    /** a held pop-up went to an ad, or elsewhere: it goes, never shown */
    fun denyPopup(p: Tab, from: Tab, url: String?)
    /** a pop-up may open as a tab: the same site, or a sign-in, and never an ad */
    fun popupAllowed(from: Tab, url: String): Boolean
    /** a held pop-up that went nowhere in 8 seconds goes */
    fun schedulePopupTimeout(p: Tab, from: Tab)
    /** a page closed its own window (or a pop-up's): the tab goes with it */
    fun closeWindow(page: PageView)
    /** a video went full screen (view) or left it (null); exit dismisses it */
    fun onFullscreen(t: Tab, view: View?, exit: () -> Unit)
    /** a download the page started: the engine gives the address and what it knows */
    fun onDownload(t: Tab, url: String, agent: String?, disposition: String?, mime: String?, length: Long, cookies: String?, suggested: String? = null)
    /** one request stopped on this page */
    fun onBlocked(t: Tab)
}

/** a script that runs before a page's own, on the pages whose addresses match */
data class DocumentScript(val code: String, val patterns: Set<String>)

/** the page engine: it makes pages, and knows the engine's own names */
interface Engine {
    /** containers (profiles) work in this engine */
    val containersSupported: Boolean
    /** scripts can run before a page's own (document start) */
    val supportsDocumentStartScript: Boolean
    /** the activity changed (remade): pages made in its context follow it */
    fun onActivityChanged(activity: Activity?) {}

    /** whether a page of this engine is playing sound right now: Cefrium
     *  asks its browser (its own audio state); System WebView has no such
     *  query, so it answers from the page's report alone (false here) */
    fun isPlayingAudio(tab: Tab): Boolean = false

    /** the tab's page, made on first use (null until the activity is here) */
    fun createPage(tab: Tab, model: BrowserModel): PageView?
    fun engineName(): String
    fun mobileAgent(): String
    /** the private tabs' profile is wiped when the last one closes */
    fun clearPrivateData()
    /** a container's profile and everything its sites kept go */
    fun deleteProfile(name: String)
}

/** the engine's names, for the about line and downloads */
object Pages {
    fun engine(): String = EngineFactory.create().engineName()
    fun mobileAgent(): String = EngineFactory.create().mobileAgent()
}
