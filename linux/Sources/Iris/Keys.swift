import CAdwaita
import CWebKit
import Foundation

/// The keyboard: the usual browser keys, before the page sees them.
enum Keys {
    static func attach(_ b: Browser) {
        let k = gtk_event_controller_key_new()!
        gtk_event_controller_set_propagation_phase(k, GTK_PHASE_CAPTURE)
        onKey(Ptr(k)) { [unowned b] key, state in handle(b, Int32(key), state) }
        gtk_widget_add_controller(b.window, k)
    }

    static func handle(_ b: Browser, _ key: Int32, _ state: UInt32) -> Bool {
        let ctrl = state & GDK_CONTROL_MASK.rawValue != 0
        let shift = state & GDK_SHIFT_MASK.rawValue != 0
        let alt = state & GDK_ALT_MASK.rawValue != 0
        let lower = Int32(gdk_keyval_to_lower(guint(key)))
        if ctrl && !alt {
            switch lower {
            case GDK_KEY_t: if shift { b.reopenClosed() } else { b.newTab() }; return true
            case GDK_KEY_n: if shift { b.newTab(container: Container.privateID) } else { b.app?.newWindow() }; return true
            case GDK_KEY_w: b.closeCurrent(); return true
            case GDK_KEY_q: b.app?.quit(); return true
            case GDK_KEY_l, GDK_KEY_k: b.focusAddress(); return true
            case GDK_KEY_r: if shift { if let w = b.current?.webView { webkit_web_view_reload_bypass_cache(w) } } else { b.current?.reload() }; return true
            case GDK_KEY_f: b.openFind(); return true
            case GDK_KEY_y where shift: b.showDownloads(); return true
            case GDK_KEY_j: b.showDownloads(); return true
            case GDK_KEY_h: b.showHistory(); return true
            case GDK_KEY_plus, GDK_KEY_equal, GDK_KEY_KP_Add: b.zoom(1); return true
            case GDK_KEY_minus, GDK_KEY_KP_Subtract: b.zoom(-1); return true
            case GDK_KEY_0, GDK_KEY_KP_0: b.zoom(0); return true
            case GDK_KEY_Tab, GDK_KEY_ISO_Left_Tab: b.cycle(shift || key == GDK_KEY_ISO_Left_Tab ? -1 : 1); return true
            case GDK_KEY_Page_Down: b.cycle(1); return true
            case GDK_KEY_Page_Up: b.cycle(-1); return true
            case GDK_KEY_1...GDK_KEY_9: b.selectIndex(Int(lower - GDK_KEY_1)); return true
            default: break
            }
        }
        if alt && !ctrl {
            switch key {
            case GDK_KEY_Left: b.current?.back(); return true
            case GDK_KEY_Right: b.current?.forward(); return true
            case GDK_KEY_Home: b.go("about:blank"); return true
            default: break
            }
        }
        switch key {
        case GDK_KEY_F5: b.current?.reload(); return true
        case GDK_KEY_F6: b.focusAddress(); return true
        case GDK_KEY_F11: b.toggleWindowFullscreen(); return true
        case GDK_KEY_Escape where b.menu != nil: b.closeMenu(); return true
        case GDK_KEY_Escape where b.fullscreen: b.toggleWindowFullscreen(); return true
        default: return false
        }
    }
}
