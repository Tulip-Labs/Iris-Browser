// Dead keys and the compose key (libxkbcommon's compose tables).
package main

import "core:strings"
import plat "../plat"

foreign import xkbc "system:xkbcommon"

Xkb_Compose_Table :: struct {}
Xkb_Compose_State :: struct {}

XKB_COMPOSE_STATUS_NOTHING :: 0
XKB_COMPOSE_STATUS_COMPOSING :: 1
XKB_COMPOSE_STATUS_COMPOSED :: 2
XKB_COMPOSE_STATUS_CANCELLED :: 3

@(default_calling_convention = "c")
foreign xkbc {
	xkb_compose_table_new_from_locale :: proc(ctx: ^plat.Xkb_Context, locale: cstring, flags: i32) -> ^Xkb_Compose_Table ---
	xkb_compose_table_unref :: proc(t: ^Xkb_Compose_Table) ---
	xkb_compose_state_new :: proc(t: ^Xkb_Compose_Table, flags: i32) -> ^Xkb_Compose_State ---
	xkb_compose_state_unref :: proc(s: ^Xkb_Compose_State) ---
	xkb_compose_state_feed :: proc(s: ^Xkb_Compose_State, keysym: u32) -> i32 ---
	xkb_compose_state_reset :: proc(s: ^Xkb_Compose_State) ---
	xkb_compose_state_get_status :: proc(s: ^Xkb_Compose_State) -> i32 ---
	xkb_compose_state_get_utf8 :: proc(s: ^Xkb_Compose_State, buf: [^]u8, size: uint) -> i32 ---
}

Compose :: struct {
	table: ^Xkb_Compose_Table,
	state: ^Xkb_Compose_State,
	buf:   [32]u8,
	tried: bool,
}

compose_init :: proc(c: ^Compose, ctx: ^plat.Xkb_Context) {
	if c.state != nil || ctx == nil do return
	loc := env("LC_ALL")
	if loc == "" do loc = env("LC_CTYPE")
	if loc == "" do loc = env("LANG")
	if loc == "" do loc = "en_US.UTF-8"
	c.table = xkb_compose_table_new_from_locale(ctx, strings.clone_to_cstring(loc, context.temp_allocator), 0)
	if c.table != nil do c.state = xkb_compose_state_new(c.table, 0)
}

Compose_Result :: enum u8 { Pass, Swallow, Text }

/// a key press: Pass (type it as it is), Swallow (part of a sequence) or
/// Text (the composed character)
compose_key :: proc(c: ^Compose, keysym: u32) -> (res: Compose_Result, text: string) {
	if c.state == nil do return .Pass, ""
	// the modifier keys themselves do not take part
	if keysym >= 0xffe1 && keysym <= 0xffee do return .Pass, ""
	if keysym == 0xfe03 || keysym == 0xff7e do return .Pass, ""
	if xkb_compose_state_feed(c.state, keysym) == 0 do return .Pass, ""
	switch xkb_compose_state_get_status(c.state) {
	case XKB_COMPOSE_STATUS_COMPOSING: return .Swallow, ""
	case XKB_COMPOSE_STATUS_COMPOSED:
		n := xkb_compose_state_get_utf8(c.state, &c.buf[0], len(c.buf))
		xkb_compose_state_reset(c.state)
		if n > 0 do return .Text, string(c.buf[:min(int(n), len(c.buf) - 1)])
		return .Swallow, ""
	case XKB_COMPOSE_STATUS_CANCELLED:
		xkb_compose_state_reset(c.state)
		return .Swallow, ""
	}
	return .Pass, ""
}

compose_reset :: proc(c: ^Compose) {
	if c.state != nil do xkb_compose_state_reset(c.state)
}
