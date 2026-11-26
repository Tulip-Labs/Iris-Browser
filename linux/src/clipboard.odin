// The desktop's clipboard (Wayland's data device) and the page's, kept in
// step: what a page copies, other apps can paste; what the desktop copies,
// pages can paste.
package iris

import "base:runtime"
import "core:strings"
import "core:sys/linux"
import wl "../wl"
import plat "../plat"

@(private="file") Clip :: struct {
	win:      ^plat.Window,
	device:   ^wl.Wl_Data_Device,
	source:   ^wl.Wl_Data_Source,
	text:     string, // what Iris offers
	reading:  [dynamic]u8,
	read_fd:  linux.Fd,
	ctx:      runtime.Context,
	has_text: map[rawptr]bool, // offers with text
}

@(private="file") clip: Clip

/// the text on the clipboard (the desktop's, or what Iris copied), for the
/// chrome's fields (and, in the CEF engine, what a page pastes)
clipboard_text: string

TEXT_TYPES :: [?]cstring{"text/plain;charset=utf-8", "text/plain", "UTF8_STRING", "TEXT", "STRING"}

clipboard_init :: proc(w: ^plat.Window) {
	clip.win = w
	clip.ctx = context
	clip.read_fd = -1
	if w.data_devices == nil || w.seat == nil do return
	clip.device = wl.wl_data_device_manager_get_data_device(w.data_devices, w.seat)
	wl.wl_data_device_add_listener(clip.device, &device_listener, nil)
}

@(private="file") offer_listener := wl.Wl_Data_Offer_Listener {
	offer = proc "c" (data: rawptr, o: ^wl.Wl_Data_Offer, mime: cstring) {
		context = clip.ctx
		for t in TEXT_TYPES do if string(t) == string(mime) do clip.has_text[o] = true
	},
	source_actions = proc "c" (data: rawptr, o: ^wl.Wl_Data_Offer, actions: u32) {},
	action = proc "c" (data: rawptr, o: ^wl.Wl_Data_Offer, action: u32) {},
}

@(private="file") device_listener := wl.Wl_Data_Device_Listener {
	data_offer = proc "c" (data: rawptr, d: ^wl.Wl_Data_Device, o: ^wl.Wl_Data_Offer) {
		wl.wl_data_offer_add_listener(o, &offer_listener, nil)
	},
	enter = proc "c" (data: rawptr, d: ^wl.Wl_Data_Device, serial: u32, s: ^wl.Wl_Surface, x, y: wl.Fixed, o: ^wl.Wl_Data_Offer) {},
	leave = proc "c" (data: rawptr, d: ^wl.Wl_Data_Device) {},
	motion = proc "c" (data: rawptr, d: ^wl.Wl_Data_Device, time: u32, x, y: wl.Fixed) {},
	drop = proc "c" (data: rawptr, d: ^wl.Wl_Data_Device) {},
	selection = proc "c" (data: rawptr, d: ^wl.Wl_Data_Device, o: ^wl.Wl_Data_Offer) {
		context = clip.ctx
		if o == nil do return
		has := clip.has_text[o]
		delete_key(&clip.has_text, rawptr(o))
		// Iris's own copy coming back: nothing to read
		if !has || clip.source != nil {
			wl.wl_data_offer_destroy(o)
			return
		}
		read_offer(o)
	},
}

@(private="file") read_offer :: proc(o: ^wl.Wl_Data_Offer) {
	fds: [2]linux.Fd
	if linux.pipe2(&fds, {.CLOEXEC}) != .NONE {
		wl.wl_data_offer_destroy(o)
		return
	}
	wl.wl_data_offer_receive(o, TEXT_TYPES[0], i32(fds[1]))
	linux.close(fds[1])
	wl.display_flush(clip.win.display)
	wl.wl_data_offer_destroy(o)
	if clip.read_fd >= 0 do linux.close(clip.read_fd)
	clip.read_fd = fds[0]
	clear(&clip.reading)
	g_unix_fd_add_full(G_PRIORITY_DEFAULT, i32(fds[0]), G_IO_IN, proc "c" (fd: i32, cond: u32, data: rawptr) -> gboolean {
		context = clip.ctx
		buf: [4096]u8
		n, err := linux.read(linux.Fd(fd), buf[:])
		if n > 0 && len(clip.reading) < 1 << 24 {
			append(&clip.reading, ..buf[:n])
			return 1
		}
		linux.close(linux.Fd(fd))
		if linux.Fd(fd) == clip.read_fd do clip.read_fd = -1
		if err == .NONE && len(clip.reading) > 0 do clipboard_from_desktop(string(clip.reading[:]))
		return 0
	}, nil, nil)
}

@(private="file") source_listener := wl.Wl_Data_Source_Listener {
	target = proc "c" (data: rawptr, s: ^wl.Wl_Data_Source, mime: cstring) {},
	send = proc "c" (data: rawptr, s: ^wl.Wl_Data_Source, mime: cstring, fd: i32) {
		context = clip.ctx
		b := transmute([]u8)clip.text
		for len(b) > 0 {
			n, err := linux.write(linux.Fd(fd), b)
			if err != .NONE || n <= 0 do break
			b = b[n:]
		}
		linux.close(linux.Fd(fd))
	},
	cancelled = proc "c" (data: rawptr, s: ^wl.Wl_Data_Source) {
		context = clip.ctx
		wl.wl_data_source_destroy(s)
		if clip.source == s do clip.source = nil
	},
	dnd_drop_performed = proc "c" (data: rawptr, s: ^wl.Wl_Data_Source) {},
	dnd_finished = proc "c" (data: rawptr, s: ^wl.Wl_Data_Source) {},
	action = proc "c" (data: rawptr, s: ^wl.Wl_Data_Source, a: u32) {},
}

/// a page (or the address bar) copied text: the desktop gets it
clipboard_offer :: proc(text: string) {
	if clip.device == nil do return
	delete(clip.text)
	clip.text = strings.clone(text)
	delete(clipboard_text)
	clipboard_text = strings.clone(text)
	if clip.source != nil do wl.wl_data_source_destroy(clip.source)
	clip.source = wl.wl_data_device_manager_create_data_source(clip.win.data_devices)
	wl.wl_data_source_add_listener(clip.source, &source_listener, nil)
	for t in TEXT_TYPES do wl.wl_data_source_offer(clip.source, t)
	wl.wl_data_device_set_selection(clip.device, clip.source, clip.win.last_serial)
	wl.display_flush(clip.win.display)
}
