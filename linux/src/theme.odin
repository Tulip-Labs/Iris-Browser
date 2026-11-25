// Light or dark, and whether the desktop wants less motion: what the
// desktop says (the XDG settings portal: org.freedesktop.appearance and
// GNOME's enable-animations), or IRIS_THEME=dark|light and
// IRIS_REDUCE_MOTION=1. The palette is neutral: clear glass, graphite ink,
// one blue; no purple anywhere.
package iris

import "core:os"

Theme :: struct {
	dark:          bool,
	reduce_motion: bool,
	/// the user chose by the environment: the portal does not overrule it
	fixed_dark, fixed_motion: bool,
}

theme: Theme

INK: [4]f32
DIM: [4]f32
FAINT: [4]f32
ACCENT: [4]f32
WARN :: [4]f32{0.91, 0.35, 0.05, 1}
WHITE :: [4]f32{1, 1, 1, 1}

/// the ink and the one accent, for light or dark
palette_apply :: proc() {
	if theme.dark {
		INK = {0.95, 0.96, 0.97, 1}
		DIM = {0.95, 0.96, 0.97, 0.6}
		FAINT = {1, 1, 1, 0.14}
		ACCENT = {0.04, 0.52, 1.0, 1} // the system blue
	} else {
		INK = {0.10, 0.11, 0.13, 1}
		DIM = {0.10, 0.11, 0.13, 0.6}
		FAINT = {0.10, 0.11, 0.13, 0.12}
		ACCENT = {0.0, 0.48, 1.0, 1}
	}
}

theme_init :: proc() {
	switch os.get_env("IRIS_THEME", context.temp_allocator) {
	case "dark": theme.dark, theme.fixed_dark = true, true
	case "light": theme.dark, theme.fixed_dark = false, true
	}
	if m := os.get_env("IRIS_REDUCE_MOTION", context.temp_allocator); len(m) > 0 {
		theme.reduce_motion, theme.fixed_motion = m != "0", true
	}
	palette_apply()
	engine_set_color_scheme(theme.dark)
	if theme.fixed_dark && theme.fixed_motion do return
	if !theme.fixed_dark do portal_setting("org.freedesktop.appearance", "color-scheme")
	if !theme.fixed_motion do portal_setting("org.gnome.desktop.interface", "enable-animations")
	// and every change after, as the desktop makes it (no polling)
	bus := g_bus_get_sync(G_BUS_TYPE_SESSION, nil, nil)
	if bus == nil do return
	g_dbus_connection_signal_subscribe(bus, "org.freedesktop.portal.Desktop", "org.freedesktop.portal.Settings", "SettingChanged", "/org/freedesktop/portal/desktop", nil, 0,
		rawptr(proc "c" (c: ^GDBusConnection, sender, path, iface, signal: cstring, params: ^GVariant, data: rawptr) {
			context = main_context
			if params == nil || string(g_variant_get_type_string(params)) != "(ssv)" do return
			ns := g_variant_get_child_value(params, 0)
			key := g_variant_get_child_value(params, 1)
			defer {
				g_variant_unref(ns)
				g_variant_unref(key)
			}
			theme_setting(string(g_variant_get_string(ns, nil)), string(g_variant_get_string(key, nil)), g_variant_get_child_value(params, 2))
		}), nil, nil)
}

/// a setting the portal gave (read, or changed): v is taken (unreferenced here)
@(private="file") theme_setting :: proc(ns, key: string, v0: ^GVariant) {
	v := v0
	if v == nil do return
	// Read answers a variant in a variant; SettingChanged one variant
	for string(g_variant_get_type_string(v)) == "v" {
		inner := g_variant_get_variant(v)
		g_variant_unref(v)
		v = inner
	}
	defer g_variant_unref(v)
	ty := string(g_variant_get_type_string(v))
	switch {
	case ns == "org.freedesktop.appearance" && key == "color-scheme" && ty == "u":
		if theme.fixed_dark do return
		dark := g_variant_get_uint32(v) == 1 // 1 prefers dark
		if dark == theme.dark do return
		theme.dark = dark
		palette_apply()
		// the pages too: prefers-color-scheme follows Iris
		engine_set_color_scheme(dark)
	case ns == "org.gnome.desktop.interface" && key == "enable-animations" && ty == "b":
		if theme.fixed_motion do return
		theme.reduce_motion = g_variant_get_boolean(v) == 0
	case: return
	}
	chrome_push()
}

Portal_Read :: struct {
	ns, key: string,
}

/// one setting from the portal, answered later (Iris does not wait for it)
@(private="file") portal_setting :: proc(ns, key: cstring) {
	bus := g_bus_get_sync(G_BUS_TYPE_SESSION, nil, nil)
	if bus == nil do return
	args := [2]^GVariant{g_variant_new_string(ns), g_variant_new_string(key)}
	r := new(Portal_Read)
	r^ = {string(ns), string(key)} // (literals: they live as long as Iris)
	g_dbus_connection_call(bus, "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop", "org.freedesktop.portal.Settings", "Read",
		g_variant_new_tuple(&args[0], 2), nil, 0, 2000, nil, proc "c" (o: ^GObject, res: ^GAsyncResult, data: rawptr) {
			context = main_context
			q := cast(^Portal_Read)data
			defer free(q)
			r := g_dbus_connection_call_finish(cast(^GDBusConnection)o, res, nil)
			if r == nil do return
			defer g_variant_unref(r)
			theme_setting(q.ns, q.key, g_variant_get_child_value(r, 0))
		}, r)
}
