import CAdwaita
import CWebKit
import Foundation

/// The sandbox, for sites Iris does not trust (Search.untrusted, or a
/// certificate that fails). Nothing is asked: such a site simply opens here.
///
/// - Its own WebKit web context: its pages run in web processes of their
///   own, never shared with your other tabs, each locked in WebKit's
///   bubblewrap sandbox (and Flatpak's), with no access to your files.
/// - Its own network session for each sandboxed tab, in memory only: no
///   cookie, storage, cache or sign-in of yours, and nothing it sets
///   survives the tab.
/// - Less to attack: no WebGL, WebRTC, camera, microphone, location,
///   notifications, clipboard, pop-ups or downloads.
enum Sandbox {
    static let context: OpaquePointer = {
        let c = gnew(webkit_web_context_get_type(), [.boxed("memory-pressure-settings", Ptr(Engine.pressure), webkit_memory_pressure_settings_get_type())])
        let ctx = OpaquePointer(c)
        webkit_web_context_set_cache_model(ctx, WEBKIT_CACHE_MODEL_DOCUMENT_VIEWER)
        return ctx
    }()

    /// a fresh world for one sandboxed tab, gone with it
    static func session() -> OpaquePointer {
        let s = webkit_network_session_new_ephemeral()!
        let cookies = webkit_network_session_get_cookie_manager(s)
        webkit_cookie_manager_set_accept_policy(cookies, WEBKIT_COOKIE_POLICY_ACCEPT_NO_THIRD_PARTY)
        webkit_network_session_set_itp_enabled(s, 1)
        return s
    }

    static func settings() -> OpaquePointer {
        let s = webkit_settings_new()!
        webkit_settings_set_enable_developer_extras(s, 0)
        webkit_settings_set_javascript_can_open_windows_automatically(s, 0)
        webkit_settings_set_javascript_can_access_clipboard(s, 0)
        webkit_settings_set_enable_webgl(s, 0)
        webkit_settings_set_enable_webrtc(s, 0)
        webkit_settings_set_enable_media_stream(s, 0)
        webkit_settings_set_enable_encrypted_media(s, 0)
        webkit_settings_set_allow_file_access_from_file_urls(s, 0)
        webkit_settings_set_allow_universal_access_from_file_urls(s, 0)
        webkit_settings_set_enable_back_forward_navigation_gestures(s, 1)
        webkit_settings_set_enable_smooth_scrolling(s, 1)
        return s
    }
}
