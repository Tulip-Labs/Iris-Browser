import CAdwaita
import CWebKit
import Foundation

/// What every tab shares: one WebKit web context (one pool of web processes
/// and caches for all tabs; containers keep their own network sessions, so
/// their cookies and storage stay apart), with a memory limit per web
/// process so a heavy page gives memory back early instead of growing.
enum Engine {
    /// the computer's memory, in MB
    static let memoryMB: Int = {
        let pages = sysconf(Int32(_SC_PHYS_PAGES)), size = sysconf(Int32(_SC_PAGESIZE))
        return pages > 0 && size > 0 ? Int(pages) * Int(size) / (1 << 20) : 8192
    }()

    static let pressure: OpaquePointer = {
        let p = webkit_memory_pressure_settings_new()!
        // a sixth of the memory for one web process, between 512 MB and 2 GB
        webkit_memory_pressure_settings_set_memory_limit(p, guint(min(2048, max(512, memoryMB / 6))))
        webkit_memory_pressure_settings_set_conservative_threshold(p, 0.33)
        webkit_memory_pressure_settings_set_strict_threshold(p, 0.5)
        webkit_memory_pressure_settings_set_poll_interval(p, 5)
        return p
    }()

    static let context: OpaquePointer = {
        // the network process too (one for all sessions)
        webkit_network_session_set_memory_pressure_settings(pressure)
        let c = gnew(webkit_web_context_get_type(), [.boxed("memory-pressure-settings", Ptr(pressure), webkit_memory_pressure_settings_get_type())])
        let ctx = OpaquePointer(c)
        // caches sized for a browser, smaller on computers with little memory
        webkit_web_context_set_cache_model(ctx, memoryMB <= 8192 ? WEBKIT_CACHE_MODEL_DOCUMENT_BROWSER : WEBKIT_CACHE_MODEL_WEB_BROWSER)
        return ctx
    }()

    /// YouTube asks the browser which video formats it plays; told that VP9
    /// and AV1 are not among them, it sends H.264, which costs a fraction of
    /// the processor time (the idea of the h264ify extension)
    static let lightVideoScript = """
    (() => {
      const heavy = /vp0?9|vp8|av01/i;
      for (const MS of [window.MediaSource, window.ManagedMediaSource]) {
        if (MS && MS.isTypeSupported) {
          const ok = MS.isTypeSupported.bind(MS);
          MS.isTypeSupported = t => heavy.test(t) ? false : ok(t);
        }
      }
      const can = HTMLMediaElement.prototype.canPlayType;
      HTMLMediaElement.prototype.canPlayType = function (t) { return heavy.test(t) ? '' : can.call(this, t); };
    })();
    """

    static func addLightVideo(_ ucm: OpaquePointer) {
        guard SettingsStore.shared.value.lightVideo else { return }
        let hosts = ["https://*.youtube.com/*", "https://youtube.com/*", "https://*.youtube-nocookie.com/*"]
        var cs = hosts.map { strdup($0) } + [nil]
        let script = cs.withUnsafeMutableBufferPointer { b in
            b.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: b.count) {
                webkit_user_script_new(lightVideoScript, WEBKIT_USER_CONTENT_INJECT_ALL_FRAMES, WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START, $0, nil)
            }
        }
        cs.forEach { free($0) }
        if let script {
            webkit_user_content_manager_add_script(ucm, script)
            webkit_user_script_unref(script)
        }
    }

    /// Hardware video decoding off: GStreamer's decoders on the graphics
    /// chip are ranked out, so video is decoded by ffmpeg on the processor.
    /// Must run before GStreamer starts (the web processes inherit it).
    static func videoEnvironment() {
        if SettingsStore.shared.value.hardwareVideo { return }
        let off = ["vah264dec", "vah265dec", "vavp8dec", "vavp9dec", "vaav1dec", "vampeg2dec",
                   "vaapih264dec", "vaapih265dec", "vaapivp8dec", "vaapivp9dec", "vaapiav1dec",
                   "nvh264dec", "nvh265dec", "nvvp9dec", "nvav1dec",
                   "v4l2slh264dec", "v4l2slh265dec", "v4l2slvp9dec", "v4l2slav1dec"].map { $0 + ":NONE" }
        var all = off
        if let have = getenv("GST_PLUGIN_FEATURE_RANK").map({ String(cString: $0) }), !have.isEmpty { all.insert(have, at: 0) }
        setenv("GST_PLUGIN_FEATURE_RANK", all.joined(separator: ","), 1)
    }
}
