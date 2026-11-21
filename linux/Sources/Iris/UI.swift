import CAdwaita
import Foundation

// Plain GTK pieces the browser is built from. They draw no backgrounds of
// their own: the Stage puts glass under them.

enum UI {
    static func cls(_ w: GtkW, _ names: String...) {
        for n in names { gtk_widget_add_css_class(w, n) }
    }

    static func box(_ vertical: Bool = false, _ spacing: Int32 = 0) -> GtkW {
        gtk_box_new(vertical ? GTK_ORIENTATION_VERTICAL : GTK_ORIENTATION_HORIZONTAL, spacing)
    }

    static func append(_ box: GtkW, _ child: GtkW) {
        gtk_box_append(UnsafeMutablePointer<GtkBox>(OpaquePointer(box)), child)
    }

    static func label(_ text: String, _ classes: String...) -> GtkW {
        let l = gtk_label_new(text)!
        for c in classes { gtk_widget_add_css_class(l, c) }
        return l
    }

    static func setLabel(_ l: GtkW, _ text: String) {
        gtk_label_set_text(OpaquePointer(l), text)
    }

    static func ellipsize(_ l: GtkW, chars: Int32 = 8) {
        let lb = OpaquePointer(l)
        gtk_label_set_ellipsize(lb, PANGO_ELLIPSIZE_END)
        gtk_label_set_width_chars(lb, chars)
        gtk_label_set_xalign(lb, 0)
    }

    static func icon(_ name: String, _ size: Int32 = 16) -> GtkW {
        let i = gtk_image_new_from_icon_name(name)!
        gtk_image_set_pixel_size(OpaquePointer(i), size)
        return i
    }

    static func button(_ iconName: String, _ tip: String, _ f: @escaping () -> Void) -> GtkW {
        let b = gtk_button_new_from_icon_name(iconName)!
        cls(b, "iris-flat", "iris-icon")
        gtk_widget_set_size_request(b, 34, 34)
        gtk_widget_set_tooltip_text(b, tip)
        gtk_widget_set_focus_on_click(b, 0)
        on(Ptr(b), "clicked", f)
        return b
    }

    /// a button with a label (menu rows, notices)
    static func textButton(_ text: String, _ f: @escaping () -> Void) -> GtkW {
        let b = gtk_button_new_with_label(text)!
        cls(b, "iris-flat", "iris-text-button")
        gtk_widget_set_focus_on_click(b, 0)
        on(Ptr(b), "clicked", f)
        return b
    }

    /// a row of a menu: icon, text and the keys that do the same
    /// a container's icon in its colour
    static func containerIcon(_ c: Container, _ size: Int32 = 16) -> GtkW {
        let i = icon(c.iconName, size)
        cls(i, c.colorClass)
        return i
    }

    static func row(_ iconName: String?, _ text: String, keys: String? = nil, dot: String? = nil, container: Container? = nil, _ f: @escaping () -> Void) -> GtkW {
        let b = gtk_button_new()!
        cls(b, "iris-flat", "iris-row")
        gtk_widget_set_focus_on_click(b, 0)
        let h = box(false, 10)
        if let container {
            append(h, containerIcon(container))
        } else if let dot {
            let d = gtk_drawing_area_new()!
            gtk_widget_set_size_request(d, 16, 16)
            gtk_widget_set_valign(d, GTK_ALIGN_CENTER)
            let rgba = RGBA(hex: dot)
            setDot(d, rgba)
            append(h, d)
        } else if let iconName {
            append(h, icon(iconName))
        }
        let l = label(text)
        gtk_label_set_xalign(OpaquePointer(l), 0)
        gtk_widget_set_hexpand(l, 1)
        append(h, l)
        if let keys { append(h, label(keys, "iris-dim", "iris-keys")) }
        gtk_button_set_child(UnsafeMutablePointer<GtkButton>(OpaquePointer(b)), h)
        on(Ptr(b), "clicked", f)
        return b
    }

    static func separator() -> GtkW {
        let s = gtk_separator_new(GTK_ORIENTATION_HORIZONTAL)!
        cls(s, "iris-sep")
        return s
    }

    /// a small coloured dot (a container's colour)
    static func setDot(_ area: GtkW, _ c: RGBA) {
        let data = Unmanaged.passRetained(Box(c)).toOpaque()
        gtk_drawing_area_set_draw_func(UnsafeMutablePointer<GtkDrawingArea>(OpaquePointer(area)), { _, cr, w, h, d in
            let c = Unmanaged<Box<RGBA>>.fromOpaque(d!).takeUnretainedValue().f
            let r = Double(min(w, h)) / 2 - 2.5
            cairo_arc(cr, Double(w) / 2, Double(h) / 2, r, 0, 2 * Double.pi)
            cairo_set_source_rgba(cr, c.r, c.g, c.b, c.a)
            cairo_fill_preserve(cr)
            cairo_set_source_rgba(cr, 1, 1, 1, 0.7)
            cairo_set_line_width(cr, 1)
            cairo_stroke(cr)
        }, data, { d in Unmanaged<Box<RGBA>>.fromOpaque(d!).release() })
        gtk_widget_queue_draw(area)
    }

    static func dot(_ c: RGBA, size: Int32 = 12) -> GtkW {
        let d = gtk_drawing_area_new()!
        gtk_widget_set_size_request(d, size, size)
        gtk_widget_set_valign(d, GTK_ALIGN_CENTER)
        setDot(d, c)
        return d
    }

    static func natural(_ w: GtkW, forWidth: Int32 = -1) -> (Double, Double) {
        var mw: Int32 = 0, nw: Int32 = 0, mh: Int32 = 0, nh: Int32 = 0
        gtk_widget_measure(w, GTK_ORIENTATION_HORIZONTAL, -1, &mw, &nw, nil, nil)
        gtk_widget_measure(w, GTK_ORIENTATION_VERTICAL, forWidth > 0 ? forWidth : nw, &mh, &nh, nil, nil)
        return (Double(nw), Double(nh))
    }

    static func text(_ t: GtkW) -> String {
        str(gtk_editable_get_text(OpaquePointer(t))) ?? ""
    }

    static func setText(_ t: GtkW, _ s: String) {
        gtk_editable_set_text(OpaquePointer(t), s)
    }

    nonisolated(unsafe) private static var provider: OpaquePointer?

    /// Iris's style sheet, in the look's colours
    static func installCSS() {
        let p = gtk_css_provider_new()!
        provider = OpaquePointer(p)
        gtk_css_provider_load_from_string(p, css)
        gtk_style_context_add_provider_for_display(gdk_display_get_default(), OpaquePointer(p), 600)
    }

    static func reloadCSS() {
        if let p = provider { gtk_css_provider_load_from_string(UnsafeMutablePointer(p), css) }
    }

    static var css: String {
        let ink = Look.dark ? "#f5f5f7" : "#1c1c21"
        var s = baseCSS.replacingOccurrences(of: "#1c1c21", with: ink)
        if Look.dark {
            s = s.replacingOccurrences(of: "background: alpha(white, .55); border-radius: 999px; box-shadow: inset 0 0 0 1px alpha(white, .8);",
                                       with: "background: alpha(white, .10); border-radius: 999px; box-shadow: inset 0 0 0 1px alpha(white, .22);")
                .replacingOccurrences(of: "windowcontrols button:hover { background: alpha(white, .85); }", with: "windowcontrols button:hover { background: alpha(white, .2); }")
                .replacingOccurrences(of: "color: #0a6bd6;", with: "color: #64b5ff;")
        }
        for (i, c) in Container.palette.enumerated() { s += "\n.iris-c\(i) { color: \(c); }" }
        s += "\n.iris-cp { color: #5e5ce6; }"
        return s
    }

    static let baseCSS = """
    window.iris, window.iris.background { background: none; box-shadow: none; }
    window.iris.csd { border-radius: 14px; }
    iris-stage { color: #1c1c21; }
    .iris-flat, .iris-flat:hover, .iris-flat:active, .iris-flat:checked, .iris-flat:focus {
      background: none; box-shadow: none; border: none; outline: none; text-shadow: none; -gtk-icon-shadow: none; }
    .iris-flat { min-height: 0; min-width: 0; padding: 0; }
    .iris-icon { min-width: 34px; min-height: 34px; border-radius: 999px; color: #1c1c21; }
    .iris-icon:disabled { color: alpha(#1c1c21, .32); }
    .iris-icon.small { min-width: 22px; min-height: 22px; }
    .iris-tab { padding: 0 6px 0 10px; }
    .iris-tab label { font-weight: 500; font-size: 13px; }
    .iris-tab.selected label { font-weight: 600; }
    .iris-address { padding: 0 12px; }
    .iris-address text { font-size: 14.5px; background: none; caret-color: #0a84ff; }
    .iris-address text selection { background: alpha(#0a84ff, .24); color: inherit; }
    .iris-address text placeholder { color: alpha(#1c1c21, .45); }
    .iris-chip { font-size: 12px; font-weight: 600; padding: 1px 9px 1px 7px; border-radius: 999px; color: white; }
    .iris-icon-choice { min-width: 34px; min-height: 34px; border-radius: 10px; }
    .iris-icon-choice.selected { background: alpha(#0a84ff, .18); box-shadow: inset 0 0 0 2px alpha(#0a84ff, .6); }
    .iris-history-day { font-size: 12px; font-weight: 700; color: alpha(#1c1c21, .5); margin: 8px 12px 2px; }
    .iris-row { padding: 7px 12px; border-radius: 10px; min-height: 22px; }
    .iris-row.selected { background: alpha(#0a84ff, .14); }
    .iris-choice { padding: 3px 10px; border-radius: 999px; font-weight: 600; color: #1c1c21; }
    .iris-choice.selected { background: alpha(#0a84ff, .18); box-shadow: inset 0 0 0 1px alpha(#0a84ff, .45); }
    .iris-text-button { padding: 4px 12px; border-radius: 999px; font-weight: 600; color: #0a6bd6; }
    .iris-menu { padding: 6px; }
    .iris-dim { color: alpha(#1c1c21, .58); }
    .iris-keys { font-size: 12px; }
    .iris-title { font-weight: 700; font-size: 15px; }
    .iris-sep { margin: 4px 10px; background: alpha(#1c1c21, .10); min-height: 1px; }
    .iris-tile { padding: 12px 6px 10px; border-radius: 20px; min-width: 92px; }
    .iris-tile label { font-size: 12.5px; font-weight: 500; }
    .iris-ntp-title { font-size: 40px; font-weight: 800; letter-spacing: -0.8px; color: #1c1c21; }
    .iris-ntp-sub { font-size: 13px; color: alpha(#1c1c21, .7); }
    progressbar.iris trough { min-height: 4px; border-radius: 2px; background: alpha(#1c1c21, .08); }
    progressbar.iris progress { min-height: 4px; border-radius: 2px; background: #0a84ff; }
    .iris-find text { font-size: 14px; min-width: 180px; background: none; }
    .iris-toast label { font-weight: 500; }
    windowcontrols button { min-width: 26px; min-height: 26px; padding: 0; margin: 0 2px;
      background: alpha(white, .55); border-radius: 999px; box-shadow: inset 0 0 0 1px alpha(white, .8); }
    windowcontrols button:hover { background: alpha(white, .85); }
    """
}
