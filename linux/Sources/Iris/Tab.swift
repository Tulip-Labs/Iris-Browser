import CAdwaita
import CWebKit
import Foundation

/// One tab: its page (a WebKit web view, made when the tab first opens
/// something, so a new tab costs nothing) and its pill in the tab strip.
final class Tab {
    let container: String?
    var url = ""
    var title = ""
    var progress = 0.0
    var loading = false
    var canBack = false
    var canForward = false
    var zoom = 1.0
    /// an address to open when the tab is first selected (tabs restored
    /// from the last session wait until you go to them)
    var pending: String?
    /// when the tab was last the one shown
    var lastShown = Date()
    /// asleep: its page is gone (memory given back) until it is shown again
    var asleep: Bool { web == nil && pending != nil }
    weak var browser: Browser?

    private(set) var web: GtkW?
    private(set) var ucm: OpaquePointer?
    /// in the sandbox (Sandbox): a site Iris does not trust
    private(set) var sandboxed = false
    private var sandboxSession: OpaquePointer?
    /// hosts whose failing certificate the sandbox let through, once each
    private var allowedCerts: Set<String> = []
    var page: Item?

    // the pill
    let pill: GtkW
    let pillLabel: GtkW
    let favicon: GtkW
    let close: GtkW
    var pillItem: Item!

    var isPrivate: Bool { container == Container.privateID }
    var webView: UnsafeMutablePointer<WebKitWebView>? { cp(web) }

    init(browser: Browser, container: String?) {
        self.browser = browser
        self.container = container
        pill = UI.box(false, 7)
        UI.cls(pill, "iris-tab")
        favicon = UI.icon(container == Container.privateID ? "security-high-symbolic" : "web-browser-symbolic", 16)
        UI.cls(favicon, "iris-dim")
        pillLabel = UI.label("New Tab")
        UI.ellipsize(pillLabel, chars: 4)
        gtk_widget_set_hexpand(pillLabel, 1)
        close = UI.button("window-close-symbolic", "Close tab") {}
        UI.cls(close, "small"); gtk_widget_set_size_request(close, 24, 24)
        UI.append(pill, favicon)
        if let c = Containers.shared.get(container) {
            UI.append(pill, UI.containerIcon(c, 14))
        }
        UI.append(pill, pillLabel)
        UI.append(pill, close)
        gtk_widget_set_tooltip_text(pill, "New Tab")
    }

    /// the page, made on first use
    @discardableResult
    func ensureWeb(related: UnsafeMutablePointer<WebKitWebView>? = nil) -> UnsafeMutablePointer<WebKitWebView> {
        if let w = webView { return w }
        let ucm = webkit_user_content_manager_new()!
        self.ucm = ucm
        Engine.addAIGlass(ucm)
        let settings = sandboxed ? Sandbox.settings() : webkit_settings_new()!
        if !sandboxed { normalSettings(settings) }
        Engine.addLightVideo(ucm)
        var props: [Prop] = [
            .object("user-content-manager", Ptr(ucm), webkit_user_content_manager_get_type()),
            .object("settings", Ptr(settings), webkit_settings_get_type()),
        ]
        if let related {
            // a pop-up the page asked for: same world, and it may talk to
            // the page that opened it
            props.append(.object("related-view", Ptr(related), webkit_web_view_get_type()))
        } else if sandboxed {
            // the sandbox: web processes of its own, and a world in memory for this tab alone
            let ss = Sandbox.session()
            sandboxSession = ss
            props.append(.object("network-session", Ptr(ss), webkit_network_session_get_type()))
            props.append(.object("web-context", Ptr(Sandbox.context), webkit_web_context_get_type()))
        } else {
            props.append(.object("network-session", Ptr(Containers.shared.session(container)), webkit_network_session_get_type()))
            // every tab in the one shared web context
            props.append(.object("web-context", Ptr(Engine.context), webkit_web_context_get_type()))
        }
        let w = gnew(webkit_web_view_get_type(), props).assumingMemoryBound(to: GtkWidget.self)
        g_object_unref(Ptr(settings))
        g_object_ref_sink(Ptr(w))
        web = w
        Shields.shared.apply(ucm, host: nil)
        connect(cp(w)!)
        markSandbox()
        browser?.attachPage(self)
        return cp(w)!
    }

    private func normalSettings(_ settings: OpaquePointer) {
        webkit_settings_set_enable_developer_extras(settings, 1)
        webkit_settings_set_javascript_can_open_windows_automatically(settings, 0)
        webkit_settings_set_enable_back_forward_navigation_gestures(settings, 1)
        webkit_settings_set_enable_smooth_scrolling(settings, 1)
        webkit_settings_set_media_playback_requires_user_gesture(settings, 0)
        webkit_settings_set_enable_webrtc(settings, 1)
        webkit_settings_set_enable_media_stream(settings, 1)
        webkit_settings_set_enable_encrypted_media(settings, 1)
        // calls and meetings: WebRTC, the camera, the microphone and sharing
        // the screen (asked for each site, through the desktop's portals)
        webkit_settings_set_enable_media(settings, 1)
        webkit_settings_set_enable_mediasource(settings, 1)
        webkit_settings_set_enable_media_capabilities(settings, 1)
    }

    /// a sandboxed tab looks it: its pill says so
    private func markSandbox() {
        if sandboxed { UI.cls(pill, "iris-sandboxed") } else { gtk_widget_remove_css_class(pill, "iris-sandboxed") }
        gtk_image_set_from_icon_name(OpaquePointer(favicon), sandboxed ? "security-low-symbolic" : isPrivate ? "security-high-symbolic" : "web-browser-symbolic")
    }

    /// the tab's page made again, in or out of the sandbox
    private func remake(sandboxed sb: Bool) {
        if let p = page { browser?.stage.remove(p, animated: false) }
        page = nil
        destroy()
        sandboxed = sb
        allowedCerts = []
    }

    func load(_ u: String) {
        guard !u.isEmpty else { return }
        // a site Iris does not trust opens in the sandbox, and a trusted one leaves it
        let wantSandbox = Search.untrusted(u)
        if web == nil { sandboxed = wantSandbox } else if wantSandbox != sandboxed { remake(sandboxed: wantSandbox) }
        let w = ensureWeb()
        url = u
        Shields.shared.apply(ucm!, host: Search.host(u))
        webkit_web_view_load_uri(w, u)
        browser?.tabChanged(self)
    }

    private func connect(_ w: UnsafeMutablePointer<WebKitWebView>) {
        let p = Ptr(w)
        on1(p, "notify::uri") { [weak self] _ in
            guard let self, let wv = self.webView else { return }
            self.url = str(webkit_web_view_get_uri(wv)) ?? ""
            self.browser?.tabChanged(self)
        }
        on1(p, "notify::title") { [weak self] _ in
            guard let self, let wv = self.webView else { return }
            self.title = str(webkit_web_view_get_title(wv)) ?? ""
            if !self.isPrivate { History.shared.title(self.url, self.title) }
            self.browser?.tabChanged(self)
        }
        on1(p, "notify::estimated-load-progress") { [weak self] _ in
            guard let self, let wv = self.webView else { return }
            self.progress = webkit_web_view_get_estimated_load_progress(wv)
            self.browser?.progressChanged(self)
        }
        on1(p, "notify::is-loading") { [weak self] _ in
            guard let self, let wv = self.webView else { return }
            self.loading = webkit_web_view_is_loading(wv) != 0
            self.browser?.tabChanged(self)
            self.browser?.progressChanged(self)
        }
        on1(p, "notify::favicon") { [weak self] _ in self?.updateFavicon() }
        on1(p, "load-changed") { [weak self] ev in
            guard let self, let wv = self.webView else { return }
            let e = UInt32(truncatingIfNeeded: Int(bitPattern: ev))
            self.canBack = webkit_web_view_can_go_back(wv) != 0
            self.canForward = webkit_web_view_can_go_forward(wv) != 0
            if e == WEBKIT_LOAD_COMMITTED.rawValue, !self.isPrivate {
                History.shared.record(self.url, title: self.title)
            }
            self.browser?.tabChanged(self)
        }
        // what opens: the shield follows the site, new windows are checked
        onBoolPtrUInt(p, "decide-policy") { [weak self] decision, type in
            guard let self, let decision else { return false }
            return self.decide(OpaquePointer(decision), type)
        }
        // a pop-up the check let through
        let createCB: @convention(c) (Ptr?, Ptr?, Ptr?) -> Ptr? = { _, action, d in
            let tab = Unmanaged<Tab>.fromOpaque(d!).takeUnretainedValue()
            return tab.browser?.popup(from: tab, action: OpaquePointer(action)).map { Ptr($0) }
        }
        g_signal_connect_data(p, "create", unsafeBitCast(createCB, to: GCallback.self),
                              Unmanaged.passUnretained(self).toOpaque(), nil, GConnectFlags(rawValue: 0))
        // a certificate that fails: the site opens in the sandbox, without asking
        let tlsCB: @convention(c) (Ptr?, UnsafePointer<CChar>?, Ptr?, UInt32, Ptr?) -> Int32 = { _, uri, cert, _, d in
            let tab = Unmanaged<Tab>.fromOpaque(d!).takeUnretainedValue()
            guard let uri, let cert else { return 0 }
            return tab.certificateFailed(String(cString: uri), OpaquePointer(cert)) ? 1 : 0
        }
        g_signal_connect_data(p, "load-failed-with-tls-errors", unsafeBitCast(tlsCB, to: GCallback.self),
                              Unmanaged.passUnretained(self).toOpaque(), nil, GConnectFlags(rawValue: 0))
        on(p, "ready-to-show") { [weak self] in
            guard let self else { return }
            self.browser?.select(self)
        }
        on(p, "close") { [weak self] in
            guard let self else { return }
            self.browser?.close(self)
        }
        onBool2(p, "context-menu") { [weak self] menu, hit in
            guard let self, let menu, let hit else { return false }
            self.browser?.contextMenu(self, OpaquePointer(menu), OpaquePointer(hit))
            return true
        }
        on2(p, "mouse-target-changed") { [weak self] hit, _ in
            guard let self, let hit else { return }
            let h = OpaquePointer(hit)
            let link = webkit_hit_test_result_context_is_link(h) != 0 ? str(webkit_hit_test_result_get_link_uri(h)) : nil
            self.browser?.hoverLink(self, link)
        }
        onBool1(p, "permission-request") { [weak self] req in
            guard let self, let req else { return false }
            self.browser?.permission(self, OpaquePointer(req))
            return true
        }
        onBool0(p, "enter-fullscreen") { [weak self] in self?.browser?.pageFullscreen(true); return false }
        onBool0(p, "leave-fullscreen") { [weak self] in self?.browser?.pageFullscreen(false); return false }
        onBool1(p, "web-process-terminated") { [weak self] _ in
            guard let self else { return false }
            self.browser?.toast("This page stopped working.", action: ("Reload", { [weak self] in self?.reload() }))
            return false
        }
    }

    private func certificateFailed(_ uri: String, _ cert: OpaquePointer) -> Bool {
        guard let host = Search.host(uri), !allowedCerts.contains(host) else { return false }
        g_object_ref(Ptr(cert))
        // after the signal: the page that failed may be the one let go
        idle { [weak self] in
            defer { g_object_unref(Ptr(cert)) }
            guard let self else { return }
            if !self.sandboxed { self.remake(sandboxed: true) }
            let w = self.ensureWeb()
            self.allowedCerts.insert(host)
            if let s = self.sandboxSession { webkit_network_session_allow_tls_certificate_for_host(s, UnsafeMutablePointer(cert), host) }
            self.url = uri
            webkit_web_view_load_uri(w, uri)
            self.browser?.toast("\(Search.display(uri)) has a certificate that fails: it is open in the sandbox")
            self.browser?.tabChanged(self)
        }
        return true
    }

    private func decide(_ d: OpaquePointer, _ type: UInt32) -> Bool {
        if type == WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION.rawValue {
            let nav = webkit_navigation_policy_decision_get_navigation_action(d)
            if let req = webkit_navigation_action_get_request(nav), let u = str(webkit_uri_request_get_uri(req)),
               webkit_navigation_action_get_frame_name(nav) == nil {
                // a Google result: straight to it, without Google's redirect
                if let target = Search.unwrapRedirect(u) {
                    webkit_policy_decision_ignore(cp(d))
                    idle { [weak self] in self?.load(target) }
                    return true
                }
                // into the sandbox, or out of it: the page is made again
                if Search.untrusted(u) != sandboxed, u.hasPrefix("http") {
                    webkit_policy_decision_ignore(cp(d))
                    idle { [weak self] in self?.load(u) }
                    return true
                }
                // the main frame is about to open u: the shield for its site
                if let ucm { Shields.shared.apply(ucm, host: Search.host(u)) }
            }
            return false
        }
        if type == WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION.rawValue {
            return browser?.newWindow(from: self, decision: d) ?? false
        }
        if type == WEBKIT_POLICY_DECISION_TYPE_RESPONSE.rawValue {
            // what WebKit cannot show is a download
            if webkit_response_policy_decision_is_mime_type_supported(d) == 0,
               webkit_response_policy_decision_is_main_frame_main_resource(d) != 0 {
                if sandboxed {
                    // nothing from an untrusted site reaches your files
                    webkit_policy_decision_ignore(cp(d))
                    browser?.toast("Downloads are off for sites in the sandbox")
                    return true
                }
                webkit_policy_decision_download(cp(d))
                return true
            }
        }
        return false
    }

    private func updateFavicon() {
        guard let wv = webView, let tex = webkit_web_view_get_favicon(wv) else { return }
        gtk_image_set_from_paintable(OpaquePointer(favicon), OpaquePointer(tex))
        gtk_widget_remove_css_class(favicon, "iris-dim")
        browser?.stage.dirtyChrome()
    }

    func back() { if let w = webView { webkit_web_view_go_back(w) } }
    func forward() { if let w = webView { webkit_web_view_go_forward(w) } }
    func reload() { if let w = webView { webkit_web_view_reload(w) } }
    func stop() { if let w = webView { webkit_web_view_stop_loading(w) } }

    func setZoom(_ z: Double) {
        zoom = min(3, max(0.3, z))
        if let w = webView { webkit_web_view_set_zoom_level(w, zoom) }
    }

    func run(_ js: String, _ done: ((String?) -> Void)? = nil) {
        guard let w = webView else { done?(nil); return }
        let data = done.map { Unmanaged.passRetained(Box($0)).toOpaque() }
        webkit_web_view_evaluate_javascript(w, js, -1, nil, nil, nil, data == nil ? nil : { obj, res, d in
            let f = Unmanaged<Box<(String?) -> Void>>.fromOpaque(d!)
            var err: UnsafeMutablePointer<GError>?
            var out: String?
            if let v = webkit_web_view_evaluate_javascript_finish(cp(OpaquePointer(obj)), res, &err) {
                if jsc_value_is_string(v) != 0 { out = takeStr(jsc_value_to_string(v)) }
                g_object_unref(Ptr(v))
            }
            if let err { g_error_free(err) }
            f.takeUnretainedValue().f(out)
            f.release()
        }, data)
    }

    /// gives back the page's memory; the tab opens its address again when shown
    func sleep() {
        guard web != nil, !url.isEmpty else { return }
        pending = url
        if let p = page { browser?.stage.remove(p, animated: false) }
        page = nil
        destroy()
        progress = 0
        loading = false
    }

    var playingAudio: Bool { webView.map { webkit_web_view_is_playing_audio($0) != 0 } ?? false }

    func destroy() {
        if let ucm { Shields.shared.forget(ucm) }
        if let w = web {
            webkit_web_view_try_close(cp(w))
            g_object_unref(Ptr(w))
        }
        web = nil
        ucm = nil
        if let s = sandboxSession { g_object_unref(Ptr(s)) }
        sandboxSession = nil
    }
}
