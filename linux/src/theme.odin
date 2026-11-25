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
	if !theme.fixed_dark do portal_setting("org.freedesktop.appearance", "color-scheme")
	if !theme.fixed_motion do portal_setting("org.gnome.desktop.interface", "enable-animations")
}

/// one setting from the portal, answered later (Iris does not wait for it)
@(private="file") portal_setting :: proc(ns, key: cstring) {
	bus := g_bus_get_sync(G_BUS_TYPE_SESSION, nil, nil)
	if bus == nil do return
	args := [2]^GVariant{g_variant_new_string(ns), g_variant_new_string(key)}
	g_dbus_connection_call(bus, "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop", "org.freedesktop.portal.Settings", "Read",
		g_variant_new_tuple(&args[0], 2), nil, 0, 2000, nil, proc "c" (o: ^GObject, res: ^GAsyncResult, data: rawptr) {
			context = main_context
			r := g_dbus_connection_call_finish(cast(^GDBusConnection)o, res, nil)
			if r == nil do return
			defer g_variant_unref(r)
			v := g_variant_get_child_value(r, 0)
			// Read answers a variant in a variant
			for string(g_variant_get_type_string(v)) == "v" {
				inner := g_variant_get_variant(v)
				g_variant_unref(v)
				v = inner
			}
			defer g_variant_unref(v)
			switch string(g_variant_get_type_string(v)) {
			case "u": // color-scheme: 1 prefers dark
				theme.dark = g_variant_get_uint32(v) == 1
				palette_apply()
			case "b": // enable-animations
				theme.reduce_motion = g_variant_get_boolean(v) == 0
			}
			chrome_push()
		}, nil)
}
