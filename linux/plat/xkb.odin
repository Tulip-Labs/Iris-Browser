// libxkbcommon and libwayland-cursor, the few functions the window uses.
// Checked against the real headers by abi/check-c.sh.
package plat

foreign import xkbc "system:xkbcommon"
foreign import wcur "system:wayland-cursor"

import wl "../wl"

Xkb_Context :: struct {}
Xkb_Keymap :: struct {}
Xkb_State :: struct {}

XKB_KEYMAP_FORMAT_TEXT_V1 :: 1
XKB_STATE_MODS_EFFECTIVE :: 1 << 3
XKB_MOD_NAME_SHIFT :: "Shift"
XKB_MOD_NAME_CTRL :: "Control"
XKB_MOD_NAME_ALT :: "Mod1"
XKB_MOD_NAME_LOGO :: "Mod4"

@(default_calling_convention = "c")
foreign xkbc {
	xkb_context_new :: proc(flags: i32) -> ^Xkb_Context ---
	xkb_context_unref :: proc(c: ^Xkb_Context) ---
	xkb_keymap_new_from_string :: proc(c: ^Xkb_Context, s: cstring, format: i32, flags: i32) -> ^Xkb_Keymap ---
	xkb_keymap_unref :: proc(k: ^Xkb_Keymap) ---
	xkb_keymap_key_repeats :: proc(k: ^Xkb_Keymap, key: u32) -> i32 ---
	xkb_state_new :: proc(k: ^Xkb_Keymap) -> ^Xkb_State ---
	xkb_state_unref :: proc(s: ^Xkb_State) ---
	xkb_state_update_mask :: proc(s: ^Xkb_State, depressed, latched, locked, d_layout, l_layout, locked_layout: u32) -> i32 ---
	xkb_state_key_get_one_sym :: proc(s: ^Xkb_State, key: u32) -> u32 ---
	xkb_state_key_get_utf8 :: proc(s: ^Xkb_State, key: u32, buffer: [^]u8, size: uint) -> i32 ---
	xkb_state_mod_name_is_active :: proc(s: ^Xkb_State, name: cstring, type: i32) -> i32 ---
	xkb_keysym_to_lower :: proc(ks: u32) -> u32 ---
}

Cursor_Theme :: struct {}

/// struct wl_cursor_image
Cursor_Image :: struct {
	width, height, hotspot_x, hotspot_y, delay: u32,
}

/// struct wl_cursor
Cursor :: struct {
	image_count: u32,
	images:      [^]^Cursor_Image,
	name:        cstring,
}

@(default_calling_convention = "c")
foreign wcur {
	wl_cursor_theme_load :: proc(name: cstring, size: i32, shm: ^wl.Wl_Shm) -> ^Cursor_Theme ---
	wl_cursor_theme_destroy :: proc(t: ^Cursor_Theme) ---
	wl_cursor_theme_get_cursor :: proc(t: ^Cursor_Theme, name: cstring) -> ^Cursor ---
	wl_cursor_image_get_buffer :: proc(img: ^Cursor_Image) -> ^wl.Wl_Buffer ---
}

// keysyms the apps use
KEY_BackSpace :: 0xff08
KEY_Tab :: 0xff09
KEY_ISO_Left_Tab :: 0xfe20
KEY_Return :: 0xff0d
KEY_KP_Enter :: 0xff8d
KEY_Escape :: 0xff1b
KEY_Home :: 0xff50
KEY_Left :: 0xff51
KEY_Up :: 0xff52
KEY_Right :: 0xff53
KEY_Down :: 0xff54
KEY_Page_Up :: 0xff55
KEY_Page_Down :: 0xff56
KEY_End :: 0xff57
KEY_Delete :: 0xffff
KEY_F5 :: 0xffc2
KEY_F6 :: 0xffc3
KEY_F11 :: 0xffc8
KEY_plus :: 0x002b
KEY_minus :: 0x002d
KEY_equal :: 0x003d
KEY_0 :: 0x0030
KEY_1 :: 0x0031
KEY_9 :: 0x0039
KEY_KP_Add :: 0xffab
KEY_KP_Subtract :: 0xffad
KEY_KP_0 :: 0xffb0
KEY_a :: 0x0061
KEY_z :: 0x007a
