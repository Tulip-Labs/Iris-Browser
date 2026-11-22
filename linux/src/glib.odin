// GLib, GObject and GIO: the parts Iris uses (WebKit's API is GObject, and
// its main loop is GLib's). Declared by hand; abi/check.sh holds every
// function and marked struct against the real headers.
package iris

import "base:runtime"

foreign import glib "system:glib-2.0"
foreign import gobject "system:gobject-2.0"
foreign import gio "system:gio-2.0"

GType :: distinct uint
gboolean :: i32

G_TYPE_BOOLEAN :: GType(5 << 2)
G_TYPE_UINT :: GType(7 << 2)
G_TYPE_STRING :: GType(16 << 2)
G_TYPE_OBJECT :: GType(20 << 2)

GObject :: struct {}
GMainLoop :: struct {}
GMainContext :: struct {}
GBytes :: struct {}
GPtrArray :: struct {}
GAsyncResult :: struct {}
GCancellable :: struct {}
GVariant :: struct {}
GVariantType :: struct {}
GDBusConnection :: struct {}
GDBusMessage :: struct {}

/// struct _GObjectClass (Iris only needs its size)
GObjectClass :: struct {
	_: [136]u8,
}

/// struct _GError
GError :: struct {
	domain:  u32,
	code:    i32,
	message: cstring,
}

/// struct _GTypeInfo
GTypeInfo :: struct {
	class_size:     u16,
	base_init:      rawptr,
	base_finalize:  rawptr,
	class_init:     proc "c" (klass: rawptr, data: rawptr),
	class_finalize: rawptr,
	class_data:     rawptr,
	instance_size:  u16,
	n_preallocs:    u16,
	instance_init:  rawptr,
	value_table:    rawptr,
}

/// struct _GTypeQuery
GTypeQuery :: struct {
	type:          GType,
	type_name:     cstring,
	class_size:    u32,
	instance_size: u32,
}

/// struct _GValue
GValue :: struct {
	g_type: GType,
	_data:  [2]u64,
}

GCallback :: rawptr
GDestroyNotify :: proc "c" (data: rawptr)
GSourceFunc :: proc "c" (data: rawptr) -> gboolean
GUnixFDSourceFunc :: proc "c" (fd: i32, condition: u32, data: rawptr) -> gboolean
GAsyncReadyCallback :: proc "c" (source: ^GObject, res: ^GAsyncResult, data: rawptr)

G_IO_IN :: u32(1)
G_PRIORITY_DEFAULT :: i32(0)
G_PRIORITY_DEFAULT_IDLE :: i32(200)
G_SIGNAL_MATCH_DATA :: u32(1 << 4)
G_CONNECT_AFTER :: u32(1)

@(default_calling_convention = "c")
foreign glib {
	g_free :: proc(p: rawptr) ---
	g_strdup :: proc(s: cstring) -> cstring ---
	g_error_free :: proc(e: ^GError) ---
	g_main_loop_new :: proc(ctx: ^GMainContext, is_running: gboolean) -> ^GMainLoop ---
	g_main_loop_run :: proc(l: ^GMainLoop) ---
	g_main_loop_quit :: proc(l: ^GMainLoop) ---
	g_main_context_iteration :: proc(ctx: ^GMainContext, may_block: gboolean) -> gboolean ---
	g_timeout_add_full :: proc(priority: i32, interval: u32, f: GSourceFunc, data: rawptr, notify: GDestroyNotify) -> u32 ---
	g_idle_add_full :: proc(priority: i32, f: GSourceFunc, data: rawptr, notify: GDestroyNotify) -> u32 ---
	g_source_remove :: proc(id: u32) -> gboolean ---
	g_unix_fd_add_full :: proc(priority: i32, fd: i32, condition: u32, f: GUnixFDSourceFunc, data: rawptr, notify: GDestroyNotify) -> u32 ---
	g_bytes_new :: proc(data: rawptr, size: uint) -> ^GBytes ---
	g_bytes_get_data :: proc(b: ^GBytes, size: ^uint) -> rawptr ---
	g_bytes_unref :: proc(b: ^GBytes) ---
	g_ptr_array_unref :: proc(a: ^GPtrArray) ---
	g_set_prgname :: proc(name: cstring) ---
	g_set_application_name :: proc(name: cstring) ---
	g_setenv :: proc(variable, value: cstring, overwrite: gboolean) -> gboolean ---
	g_spawn_async :: proc(working_directory: cstring, argv: [^]cstring, envp: [^]cstring, flags: i32, child_setup: rawptr, user_data: rawptr, child_pid: ^i32, err: ^^GError) -> gboolean ---
	g_variant_new_string :: proc(s: cstring) -> ^GVariant ---
	g_variant_new_tuple :: proc(children: [^]^GVariant, n: uint) -> ^GVariant ---
	g_variant_get_child_value :: proc(v: ^GVariant, index: uint) -> ^GVariant ---
	g_variant_get_string :: proc(v: ^GVariant, length: ^uint) -> cstring ---
	g_variant_get_uint32 :: proc(v: ^GVariant) -> u32 ---
	g_variant_lookup_value :: proc(dict: ^GVariant, key: cstring, expected: ^GVariantType) -> ^GVariant ---
	g_variant_n_children :: proc(v: ^GVariant) -> uint ---
	g_variant_unref :: proc(v: ^GVariant) ---
	g_variant_builder_new :: proc(type: ^GVariantType) -> rawptr ---
	g_variant_builder_add_value :: proc(b: rawptr, v: ^GVariant) ---
	g_variant_builder_end :: proc(b: rawptr) -> ^GVariant ---
	g_variant_builder_unref :: proc(b: rawptr) ---
	g_variant_new_dict_entry :: proc(key, value: ^GVariant) -> ^GVariant ---
	g_variant_new_variant :: proc(value: ^GVariant) -> ^GVariant ---
	g_variant_new_boolean :: proc(b: gboolean) -> ^GVariant ---
	g_variant_new_array :: proc(child_type: ^GVariantType, children: [^]^GVariant, n: uint) -> ^GVariant ---
	g_variant_type_new :: proc(s: cstring) -> ^GVariantType ---
	g_variant_type_free :: proc(t: ^GVariantType) ---
}

@(default_calling_convention = "c")
foreign gobject {
	g_type_register_static :: proc(parent: GType, name: cstring, info: ^GTypeInfo, flags: u32) -> GType ---
	g_type_query :: proc(type: GType, query: ^GTypeQuery) ---
	g_type_class_peek_parent :: proc(klass: rawptr) -> rawptr ---
	g_type_check_instance_is_a :: proc(instance: rawptr, type: GType) -> gboolean ---
	g_type_name_from_instance :: proc(instance: rawptr) -> cstring ---
	g_object_new_with_properties :: proc(type: GType, n: u32, names: [^]cstring, values: [^]GValue) -> rawptr ---
	g_object_ref :: proc(o: rawptr) -> rawptr ---
	g_object_ref_sink :: proc(o: rawptr) -> rawptr ---
	g_object_unref :: proc(o: rawptr) ---
	g_object_get_data :: proc(o: rawptr, key: cstring) -> rawptr ---
	g_object_set_data :: proc(o: rawptr, key: cstring, data: rawptr) ---
	g_object_set_data_full :: proc(o: rawptr, key: cstring, data: rawptr, destroy: GDestroyNotify) ---
	g_object_get_property :: proc(o: rawptr, name: cstring, value: ^GValue) ---
	g_object_set_property :: proc(o: rawptr, name: cstring, value: ^GValue) ---
	g_signal_connect_data :: proc(instance: rawptr, signal: cstring, handler: GCallback, data: rawptr, destroy: rawptr, flags: u32) -> u64 ---
	g_signal_handlers_disconnect_matched :: proc(instance: rawptr, mask: u32, signal_id: u32, detail: u32, closure: rawptr, f: rawptr, data: rawptr) -> u32 ---
	g_value_init :: proc(v: ^GValue, type: GType) -> ^GValue ---
	g_value_unset :: proc(v: ^GValue) ---
	g_value_set_object :: proc(v: ^GValue, o: rawptr) ---
	g_value_set_uint :: proc(v: ^GValue, x: u32) ---
	g_value_set_boolean :: proc(v: ^GValue, x: gboolean) ---
	g_value_set_string :: proc(v: ^GValue, x: cstring) ---
	g_value_get_boolean :: proc(v: ^GValue) -> gboolean ---
	g_value_get_string :: proc(v: ^GValue) -> cstring ---
}

@(default_calling_convention = "c")
foreign gio {
	g_bus_get_sync :: proc(type: i32, cancellable: ^GCancellable, err: ^^GError) -> ^GDBusConnection ---
	g_dbus_connection_call :: proc(c: ^GDBusConnection, bus_name, object_path, interface_name, method_name: cstring, parameters: ^GVariant, reply_type: ^GVariantType, flags: u32, timeout: i32, cancellable: ^GCancellable, callback: GAsyncReadyCallback, data: rawptr) ---
	g_dbus_connection_call_finish :: proc(c: ^GDBusConnection, res: ^GAsyncResult, err: ^^GError) -> ^GVariant ---
	g_dbus_connection_signal_subscribe :: proc(c: ^GDBusConnection, sender, interface_name, member, object_path, arg0: cstring, flags: u32, callback: rawptr, data: rawptr, free: GDestroyNotify) -> u32 ---
	g_dbus_connection_signal_unsubscribe :: proc(c: ^GDBusConnection, id: u32) ---
}

G_BUS_TYPE_SESSION :: i32(2)

// ---------------------------------------------------------------- helpers

/// a new GObject with properties (g_object_new's varargs are out of reach)
Prop :: struct {
	name:  cstring,
	value: union { rawptr, u32, bool, cstring },
	type:  GType, // the object type for rawptr values
}

gnew :: proc(type: GType, props: ..Prop) -> rawptr {
	names: [8]cstring
	values: [8]GValue
	n := min(len(props), 8)
	for p, i in props[:n] {
		names[i] = p.name
		switch v in p.value {
		case rawptr:
			g_value_init(&values[i], p.type)
			g_value_set_object(&values[i], v)
		case u32:
			g_value_init(&values[i], G_TYPE_UINT)
			g_value_set_uint(&values[i], v)
		case bool:
			g_value_init(&values[i], G_TYPE_BOOLEAN)
			g_value_set_boolean(&values[i], v ? 1 : 0)
		case cstring:
			g_value_init(&values[i], G_TYPE_STRING)
			g_value_set_string(&values[i], v)
		}
	}
	o := g_object_new_with_properties(type, u32(n), &names[0], &values[0])
	for i in 0 ..< n do g_value_unset(&values[i])
	return o
}

/// registers a subclass of parent with a class initialiser
register_type :: proc(parent: GType, name: cstring, class_init: proc "c" (klass: rawptr, data: rawptr)) -> GType {
	q: GTypeQuery
	g_type_query(parent, &q)
	info := GTypeInfo {
		class_size    = u16(q.class_size),
		class_init    = class_init,
		instance_size = u16(q.instance_size),
	}
	return g_type_register_static(parent, name, &info, 0)
}

unref :: proc "contextless" (p: rawptr) {
	if p != nil do g_object_unref(p)
}

get_bool :: proc(o: rawptr, name: cstring) -> bool {
	v: GValue
	g_value_init(&v, G_TYPE_BOOLEAN)
	g_object_get_property(o, name, &v)
	b := g_value_get_boolean(&v) != 0
	g_value_unset(&v)
	return b
}

is_a :: proc "contextless" (o: rawptr, t: GType) -> bool {
	return o != nil && g_type_check_instance_is_a(o, t) != 0
}

type_name :: proc "contextless" (o: rawptr) -> string {
	return string(g_type_name_from_instance(o))
}

/// connects a C callback (a proc "c" taking the signal's arguments, then data)
on :: proc "contextless" (instance: rawptr, signal: cstring, f: rawptr, data: rawptr, after := false) -> u64 {
	return g_signal_connect_data(instance, signal, f, data, nil, after ? G_CONNECT_AFTER : 0)
}

/// every handler connected with this data, gone
disconnect_all :: proc "contextless" (instance: rawptr, data: rawptr) {
	g_signal_handlers_disconnect_matched(instance, G_SIGNAL_MATCH_DATA, 0, 0, nil, nil, data)
}

// timers and idles that carry an Odin closure-like (proc + data)

@(private) Timer :: struct {
	f:     proc(data: rawptr) -> bool,
	data:  rawptr,
	ctx:   runtime.Context,
}

@(private) timer_fire :: proc "c" (d: rawptr) -> gboolean {
	t := cast(^Timer)d
	context = t.ctx
	return t.f(t.data) ? 1 : 0
}

@(private) timer_free :: proc "c" (d: rawptr) {
	t := cast(^Timer)d
	context = t.ctx
	free(t)
}

/// f(data) after ms milliseconds, again while it returns true
every :: proc(ms: u32, f: proc(data: rawptr) -> bool, data: rawptr) -> u32 {
	t := new(Timer)
	t^ = {f = f, data = data, ctx = context}
	return g_timeout_add_full(G_PRIORITY_DEFAULT, ms, timer_fire, t, timer_free)
}

/// f(data) once, after ms milliseconds
after :: proc(ms: u32, f: proc(data: rawptr), data: rawptr) -> u32 {
	Once :: struct {
		f:    proc(data: rawptr),
		data: rawptr,
	}
	o := new(Once)
	o^ = {f, data}
	return every(ms, proc(d: rawptr) -> bool {
		o := cast(^Once)d
		o.f(o.data)
		free(o)
		return false
	}, o)
}

/// f(data) when the loop is next idle
idle :: proc(f: proc(data: rawptr), data: rawptr) {
	t := new(Timer)
	Once :: struct {
		f:    proc(data: rawptr),
		data: rawptr,
	}
	o := new(Once)
	o^ = {f, data}
	t^ = {f = proc(d: rawptr) -> bool {
		o := cast(^Once)d
		o.f(o.data)
		free(o)
		return false
	}, data = o, ctx = context}
	g_idle_add_full(G_PRIORITY_DEFAULT_IDLE, timer_fire, t, timer_free)
}

/// a C string that GLib allocated, copied and freed
take_str :: proc(p: cstring, allocator := context.allocator) -> string {
	if p == nil do return ""
	s := clone_str(string(p), allocator)
	g_free(rawptr(p))
	return s
}

clone_str :: proc(s: string, allocator := context.allocator) -> string {
	b := make([]u8, len(s), allocator)
	copy(b, s)
	return string(b)
}
