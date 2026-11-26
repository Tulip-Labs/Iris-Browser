// The clipboard and the primary selection (Wayland's data device and the
// primary-selection protocol). Copying offers text; pasting asks the
// current offer for it through a pipe that the main loop reads, so nothing
// waits.
package main

import "base:runtime"
import "core:strings"
import "core:sys/linux"
import wl "../wl"
import plat "../plat"

@(private="file") Clip :: struct {
	win:       ^plat.Window,
	ctx:       runtime.Context,
	// the clipboard
	device:    ^wl.Wl_Data_Device,
	source:    ^wl.Wl_Data_Source,
	text:      string, // what we offer
	offer:     ^wl.Wl_Data_Offer, // the current selection of the desktop (text)
	pending:   ^wl.Wl_Data_Offer, // being introduced
	pending_text: bool,
	// the primary selection
	p_mgr:     ^wl.Zwp_Primary_Selection_Device_Manager_V1,
	p_device:  ^wl.Zwp_Primary_Selection_Device_V1,
	p_source:  ^wl.Zwp_Primary_Selection_Source_V1,
	p_text:    string,
	p_offer:   ^wl.Zwp_Primary_Selection_Offer_V1,
	p_pending: ^wl.Zwp_Primary_Selection_Offer_V1,
	p_pending_text: bool,
	// a paste being read
	read_fd:   linux.Fd,
	read_primary: bool,
	reading:   [dynamic]u8,
}

@(private="file") clip: Clip

TEXT_TYPES :: [?]cstring{"text/plain;charset=utf-8", "text/plain", "UTF8_STRING", "TEXT", "STRING"}

@(private="file") is_text_type :: proc "contextless" (mime: cstring) -> bool {
	for t in TEXT_TYPES do if string(t) == string(mime) do return true
	return false
}

@(private="file") registry_listener := wl.Wl_Registry_Listener {
	global = proc "c" (data: rawptr, r: ^wl.Wl_Registry, name: u32, iface: cstring, version: u32) {
		if string(iface) == "zwp_primary_selection_device_manager_v1" {
			clip.p_mgr = cast(^wl.Zwp_Primary_Selection_Device_Manager_V1)wl.wl_registry_bind(r, name, &wl.zwp_primary_selection_device_manager_v1_interface, 1)
		}
	},
	global_remove = proc "c" (data: rawptr, r: ^wl.Wl_Registry, name: u32) {},
}

clip_init :: proc(w: ^plat.Window) {
	clip.win = w
	clip.ctx = context
	clip.read_fd = -1
	if w.seat == nil do return
	if w.data_devices != nil {
		clip.device = wl.wl_data_device_manager_get_data_device(w.data_devices, w.seat)
		wl.wl_data_device_add_listener(clip.device, &device_listener, nil)
	}
	reg := wl.wl_display_get_registry(w.display)
	wl.wl_registry_add_listener(reg, &registry_listener, nil)
	wl.display_roundtrip(w.display)
	if clip.p_mgr != nil {
		clip.p_device = wl.zwp_primary_selection_device_manager_v1_get_device(clip.p_mgr, w.seat)
		wl.zwp_primary_selection_device_v1_add_listener(clip.p_device, &p_device_listener, nil)
	}
	wl.display_roundtrip(w.display)
}

// ---------------------------------------------------------------- the desktop's offers

@(private="file") offer_listener := wl.Wl_Data_Offer_Listener {
	offer = proc "c" (data: rawptr, o: ^wl.Wl_Data_Offer, mime: cstring) {
		if o == clip.pending && is_text_type(mime) do clip.pending_text = true
	},
	source_actions = proc "c" (data: rawptr, o: ^wl.Wl_Data_Offer, actions: u32) {},
	action = proc "c" (data: rawptr, o: ^wl.Wl_Data_Offer, action: u32) {},
}

@(private="file") device_listener := wl.Wl_Data_Device_Listener {
	data_offer = proc "c" (data: rawptr, d: ^wl.Wl_Data_Device, o: ^wl.Wl_Data_Offer) {
		clip.pending, clip.pending_text = o, false
		wl.wl_data_offer_add_listener(o, &offer_listener, nil)
	},
	enter = proc "c" (data: rawptr, d: ^wl.Wl_Data_Device, serial: u32, s: ^wl.Wl_Surface, x, y: wl.Fixed, o: ^wl.Wl_Data_Offer) {},
	leave = proc "c" (data: rawptr, d: ^wl.Wl_Data_Device) {},
	motion = proc "c" (data: rawptr, d: ^wl.Wl_Data_Device, time: u32, x, y: wl.Fixed) {},
	drop = proc "c" (data: rawptr, d: ^wl.Wl_Data_Device) {},
	selection = proc "c" (data: rawptr, d: ^wl.Wl_Data_Device, o: ^wl.Wl_Data_Offer) {
		if clip.offer != nil && clip.offer != o do wl.wl_data_offer_destroy(clip.offer)
		clip.offer = nil
		if o == nil do return
		if clip.pending_text {
			clip.offer = o
		} else {
			wl.wl_data_offer_destroy(o)
		}
		clip.pending = nil
	},
}

@(private="file") p_offer_listener := wl.Zwp_Primary_Selection_Offer_V1_Listener {
	offer = proc "c" (data: rawptr, o: ^wl.Zwp_Primary_Selection_Offer_V1, mime: cstring) {
		if o == clip.p_pending && is_text_type(mime) do clip.p_pending_text = true
	},
}

@(private="file") p_device_listener := wl.Zwp_Primary_Selection_Device_V1_Listener {
	data_offer = proc "c" (data: rawptr, d: ^wl.Zwp_Primary_Selection_Device_V1, o: ^wl.Zwp_Primary_Selection_Offer_V1) {
		clip.p_pending, clip.p_pending_text = o, false
		wl.zwp_primary_selection_offer_v1_add_listener(o, &p_offer_listener, nil)
	},
	selection = proc "c" (data: rawptr, d: ^wl.Zwp_Primary_Selection_Device_V1, o: ^wl.Zwp_Primary_Selection_Offer_V1) {
		if clip.p_offer != nil && clip.p_offer != o do wl.zwp_primary_selection_offer_v1_destroy(clip.p_offer)
		clip.p_offer = nil
		if o == nil do return
		if clip.p_pending_text {
			clip.p_offer = o
		} else {
			wl.zwp_primary_selection_offer_v1_destroy(o)
		}
		clip.p_pending = nil
	},
}

// ---------------------------------------------------------------- what we offer

@(private="file") send_all :: proc(fd: i32, text: string) {
	b := transmute([]u8)text
	for len(b) > 0 {
		n, err := linux.write(linux.Fd(fd), b)
		if err != .NONE || n <= 0 do break
		b = b[n:]
	}
	linux.close(linux.Fd(fd))
}

@(private="file") source_listener := wl.Wl_Data_Source_Listener {
	target = proc "c" (data: rawptr, s: ^wl.Wl_Data_Source, mime: cstring) {},
	send = proc "c" (data: rawptr, s: ^wl.Wl_Data_Source, mime: cstring, fd: i32) {
		context = clip.ctx
		send_all(fd, clip.text)
	},
	cancelled = proc "c" (data: rawptr, s: ^wl.Wl_Data_Source) {
		wl.wl_data_source_destroy(s)
		if clip.source == s do clip.source = nil
	},
	dnd_drop_performed = proc "c" (data: rawptr, s: ^wl.Wl_Data_Source) {},
	dnd_finished = proc "c" (data: rawptr, s: ^wl.Wl_Data_Source) {},
	action = proc "c" (data: rawptr, s: ^wl.Wl_Data_Source, a: u32) {},
}

@(private="file") p_source_listener := wl.Zwp_Primary_Selection_Source_V1_Listener {
	send = proc "c" (data: rawptr, s: ^wl.Zwp_Primary_Selection_Source_V1, mime: cstring, fd: i32) {
		context = clip.ctx
		send_all(fd, clip.p_text)
	},
	cancelled = proc "c" (data: rawptr, s: ^wl.Zwp_Primary_Selection_Source_V1) {
		wl.zwp_primary_selection_source_v1_destroy(s)
		if clip.p_source == s do clip.p_source = nil
	},
}

/// text on the clipboard (Ctrl+Shift+C, OSC 52)
clip_copy :: proc(text: string) {
	if clip.device == nil do return
	delete(clip.text)
	clip.text = strings.clone(text)
	if clip.source != nil do wl.wl_data_source_destroy(clip.source)
	clip.source = wl.wl_data_device_manager_create_data_source(clip.win.data_devices)
	wl.wl_data_source_add_listener(clip.source, &source_listener, nil)
	for t in TEXT_TYPES do wl.wl_data_source_offer(clip.source, t)
	wl.wl_data_device_set_selection(clip.device, clip.source, clip.win.last_serial)
	wl.display_flush(clip.win.display)
}

/// text on the primary selection (what is selected: middle click pastes it)
clip_primary :: proc(text: string) {
	if clip.p_device == nil do return
	delete(clip.p_text)
	clip.p_text = strings.clone(text)
	if clip.p_source != nil do wl.zwp_primary_selection_source_v1_destroy(clip.p_source)
	clip.p_source = wl.zwp_primary_selection_device_manager_v1_create_source(clip.p_mgr)
	wl.zwp_primary_selection_source_v1_add_listener(clip.p_source, &p_source_listener, nil)
	for t in TEXT_TYPES do wl.zwp_primary_selection_source_v1_offer(clip.p_source, t)
	wl.zwp_primary_selection_device_v1_set_selection(clip.p_device, clip.p_source, clip.win.last_serial)
	wl.display_flush(clip.win.display)
}

// ---------------------------------------------------------------- pasting

/// asks for the clipboard (or the primary selection). Our own text is
/// returned at once; the desktop's arrives later (clip_fd, clip_read)
clip_paste :: proc(primary: bool) -> (text: string, now: bool) {
	if primary {
		if clip.p_source != nil do return clip.p_text, true
		if clip.p_offer == nil do return "", false
	} else {
		if clip.source != nil do return clip.text, true
		if clip.offer == nil do return "", false
	}
	fds: [2]linux.Fd
	if linux.pipe2(&fds, {.CLOEXEC}) != .NONE do return "", false
	if primary {
		wl.zwp_primary_selection_offer_v1_receive(clip.p_offer, TEXT_TYPES[0], i32(fds[1]))
	} else {
		wl.wl_data_offer_receive(clip.offer, TEXT_TYPES[0], i32(fds[1]))
	}
	linux.close(fds[1])
	wl.display_flush(clip.win.display)
	if clip.read_fd >= 0 do linux.close(clip.read_fd)
	clip.read_fd = fds[0]
	clip.read_primary = primary
	clear(&clip.reading)
	return "", false
}

/// the pipe to wait on (-1: no paste is coming)
clip_fd :: proc() -> linux.Fd { return clip.read_fd }

/// the pipe is readable: reads; the text when it is complete
clip_read :: proc() -> (text: string, done: bool) {
	if clip.read_fd < 0 do return "", false
	buf: [8192]u8
	for {
		n, err := linux.read(clip.read_fd, buf[:])
		if err == .EAGAIN do return "", false
		if n > 0 {
			if len(clip.reading) < 1 << 24 do append(&clip.reading, ..buf[:n])
			if n < len(buf) do return "", false // poll again
			continue
		}
		break
	}
	linux.close(clip.read_fd)
	clip.read_fd = -1
	return strings.clone(string(clip.reading[:]), context.temp_allocator), true
}
