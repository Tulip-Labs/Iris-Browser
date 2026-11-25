// A page's file field: the desktop's file chooser, through the
// xdg-desktop-portal (org.freedesktop.portal.FileChooser) on D-Bus. It is
// the desktop's own dialog (GNOME's, KDE's), and inside the Flatpak the
// file you pick is the only one Iris can read.
package iris

import "core:fmt"
import "core:strings"

/// the files picked (nil-terminated, so at least 2 entries when any), or
/// nil for none: the engine hands them to the page
Picked :: proc(data: rawptr, files: []cstring)

@(private="file") Pick :: struct {
	done:   Picked,
	data:   rawptr,
	handle: string,
	sub:    u32,
}

@(private="file") bus: ^GDBusConnection
@(private="file") picks: [dynamic]^Pick
@(private="file") token_n: int

portal_open_file :: proc(multiple: bool, done: Picked, data: rawptr) {
	if bus == nil do bus = g_bus_get_sync(G_BUS_TYPE_SESSION, nil, nil)
	if bus == nil {
		done(data, nil)
		browser_toast("No file chooser: the desktop portal is not running")
		return
	}
	p := new(Pick)
	p.done, p.data = done, data
	append(&picks, p)
	// every Response signal of the portal; the one for this request is matched by its path
	p.sub = g_dbus_connection_signal_subscribe(bus, "org.freedesktop.portal.Desktop", "org.freedesktop.portal.Request", "Response", nil, nil, 0,
		rawptr(proc "c" (c: ^GDBusConnection, sender, path, iface, signal: cstring, params: ^GVariant, data: rawptr) {
			context = main_context
			picked(string(path), params)
		}), nil, nil)

	token_n += 1
	token := fmt.tprintf("iris%d", token_n)
	opts := g_variant_builder_new(g_variant_type_new("a{sv}"))
	g_variant_builder_add_value(opts, g_variant_new_dict_entry(g_variant_new_string("handle_token"), g_variant_new_variant(g_variant_new_string(cstr(token)))))
	g_variant_builder_add_value(opts, g_variant_new_dict_entry(g_variant_new_string("multiple"), g_variant_new_variant(g_variant_new_boolean(multiple ? 1 : 0))))
	g_variant_builder_add_value(opts, g_variant_new_dict_entry(g_variant_new_string("modal"), g_variant_new_variant(g_variant_new_boolean(1))))
	args := [3]^GVariant{g_variant_new_string(""), g_variant_new_string(multiple ? "Choose files" : "Choose a file"), g_variant_builder_end(opts)}
	g_variant_builder_unref(opts)
	g_dbus_connection_call(bus, "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop", "org.freedesktop.portal.FileChooser", "OpenFile",
		g_variant_new_tuple(&args[0], 3), nil, 0, -1, nil, proc "c" (o: ^GObject, res: ^GAsyncResult, data: rawptr) {
			context = main_context
			p := cast(^Pick)data
			r := g_dbus_connection_call_finish(cast(^GDBusConnection)o, res, nil)
			if r == nil {
				finish(p, nil)
				return
			}
			h := g_variant_get_child_value(r, 0)
			p.handle = strings.clone(string(g_variant_get_string(h, nil)))
			g_variant_unref(h)
			g_variant_unref(r)
		}, p)
}

/// the portal answered: 0 and the files' URIs, or a cancel
@(private="file") picked :: proc(path: string, params: ^GVariant) {
	for p in picks {
		if p.handle != path do continue
		code := g_variant_get_child_value(params, 0)
		ok := g_variant_get_uint32(code) == 0
		g_variant_unref(code)
		if !ok {
			finish(p, nil)
			return
		}
		results := g_variant_get_child_value(params, 1)
		defer g_variant_unref(results)
		as := g_variant_type_new("as")
		defer g_variant_type_free(as)
		uris := g_variant_lookup_value(results, "uris", as)
		if uris == nil {
			finish(p, nil)
			return
		}
		defer g_variant_unref(uris)
		files := make([dynamic]cstring, context.temp_allocator)
		for i in 0 ..< g_variant_n_children(uris) {
			u := g_variant_get_child_value(uris, i)
			if path, ok := file_path(string(g_variant_get_string(u, nil))); ok do append(&files, cstr(path))
			g_variant_unref(u)
		}
		append(&files, nil)
		finish(p, files[:])
		return
	}
}

/// file:///a%20b → /a b
@(private="file") file_path :: proc(uri: string) -> (string, bool) {
	if !strings.has_prefix(uri, "file://") do return "", false
	return decode(uri[len("file://"):], context.temp_allocator), true
}

@(private="file") finish :: proc(p: ^Pick, files: []cstring) {
	p.done(p.data, files)
	if p.sub != 0 do g_dbus_connection_signal_unsubscribe(bus, p.sub)
	for x, i in picks do if x == p {
		ordered_remove(&picks, i)
		break
	}
	delete(p.handle)
	free(p)
}
