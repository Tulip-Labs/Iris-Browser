// libwayland-client and libwayland-egl, declared by hand. Every type and
// procedure here is checked against the real headers by abi/ (CI runs it).
package wl

foreign import client "system:wayland-client"
foreign import wegl "system:wayland-egl"

Proxy :: struct {}
Event_Queue :: struct {}
Egl_Window :: struct {}

/// struct wl_message
Message :: struct {
	name:      cstring,
	signature: cstring,
	types:     [^]^Interface,
}

/// struct wl_interface
Interface :: struct {
	name:         cstring,
	version:      i32,
	method_count: i32,
	methods:      [^]Message,
	event_count:  i32,
	events:       [^]Message,
}

/// struct wl_array
Array :: struct {
	size:  uint,
	alloc: uint,
	data:  rawptr,
}

/// union wl_argument
Argument :: struct #raw_union {
	i: i32,
	u: u32,
	f: Fixed,
	s: cstring,
	o: rawptr,
	n: u32,
	a: ^Array,
	h: i32,
}

/// wl_fixed_t: 24.8 fixed point
Fixed :: distinct i32

fixed_to_f64 :: #force_inline proc "contextless" (f: Fixed) -> f64 { return f64(f) / 256 }
fixed_from_f64 :: #force_inline proc "contextless" (d: f64) -> Fixed { return Fixed(i32(d * 256)) }

MARSHAL_FLAG_DESTROY :: u32(1)

@(default_calling_convention = "c")
foreign client {
	@(link_name = "wl_display_connect")          display_connect :: proc(name: cstring) -> ^Wl_Display ---
	@(link_name = "wl_display_disconnect")       display_disconnect :: proc(d: ^Wl_Display) ---
	@(link_name = "wl_display_get_fd")           display_get_fd :: proc(d: ^Wl_Display) -> i32 ---
	@(link_name = "wl_display_dispatch")         display_dispatch :: proc(d: ^Wl_Display) -> i32 ---
	@(link_name = "wl_display_dispatch_pending") display_dispatch_pending :: proc(d: ^Wl_Display) -> i32 ---
	@(link_name = "wl_display_roundtrip")        display_roundtrip :: proc(d: ^Wl_Display) -> i32 ---
	@(link_name = "wl_display_flush")            display_flush :: proc(d: ^Wl_Display) -> i32 ---
	@(link_name = "wl_display_prepare_read")     display_prepare_read :: proc(d: ^Wl_Display) -> i32 ---
	@(link_name = "wl_display_read_events")      display_read_events :: proc(d: ^Wl_Display) -> i32 ---
	@(link_name = "wl_display_cancel_read")      display_cancel_read :: proc(d: ^Wl_Display) ---
	@(link_name = "wl_display_get_error")        display_get_error :: proc(d: ^Wl_Display) -> i32 ---

	@(link_name = "wl_proxy_marshal_array_flags") proxy_marshal_array_flags :: proc(p: ^Proxy, opcode: u32, interface: ^Interface, version: u32, flags: u32, args: [^]Argument) -> ^Proxy ---
	@(link_name = "wl_proxy_add_listener")       proxy_add_listener :: proc(p: ^Proxy, implementation: rawptr, data: rawptr) -> i32 ---
	@(link_name = "wl_proxy_destroy")            proxy_destroy :: proc(p: ^Proxy) ---
	@(link_name = "wl_proxy_get_version")        proxy_get_version :: proc(p: ^Proxy) -> u32 ---
	@(link_name = "wl_proxy_set_user_data")      proxy_set_user_data :: proc(p: ^Proxy, data: rawptr) ---
	@(link_name = "wl_proxy_get_user_data")      proxy_get_user_data :: proc(p: ^Proxy) -> rawptr ---
	@(link_name = "wl_proxy_get_id")             proxy_get_id :: proc(p: ^Proxy) -> u32 ---
}

@(default_calling_convention = "c")
foreign wegl {
	@(link_name = "wl_egl_window_create")  egl_window_create :: proc(surface: ^Wl_Surface, width, height: i32) -> ^Egl_Window ---
	@(link_name = "wl_egl_window_destroy") egl_window_destroy :: proc(w: ^Egl_Window) ---
	@(link_name = "wl_egl_window_resize")  egl_window_resize :: proc(w: ^Egl_Window, width, height, dx, dy: i32) ---
}
