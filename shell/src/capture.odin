// The colour of a window from the window itself, when the compositor can
// give it: ext-foreign-toplevel-list-v1 names the windows,
// ext-image-capture-source-v1 and ext-image-copy-capture-v1 copy one of
// them into a shared-memory buffer. The protocol has no way to ask for a
// small copy, so each sample is one whole window for a moment: one window at
// a time (round robin, a few a second, only windows on screen), a handful
// of pixels read from the buffer, and the buffer is gone again at once.
// Used only when all three protocols are advertised (niri may not do so);
// otherwise the colour comes from the app id and title (logic/tint.odin).
package shell

import "core:strings"
import "core:sys/linux"
import wl "../wl"
import "../logic"

SAMPLE_MS :: 500
MAX_CAPTURE_BYTES :: 64 << 20

Handle :: struct {
	h:      ^wl.Ext_Foreign_Toplevel_Handle_V1,
	title:  string,
	app_id: string,
	done:   bool,
}

Job :: struct {
	win_id:   u64,
	source:   ^wl.Ext_Image_Capture_Source_V1,
	session:  ^wl.Ext_Image_Copy_Capture_Session_V1,
	frame:    ^wl.Ext_Image_Copy_Capture_Frame_V1,
	buffer:   ^wl.Wl_Buffer,
	w, h:     u32,
	format:   u32,
	have_fmt: bool,
	mem:      rawptr,
	size:     uint,
	stride:   u32,
}

Capture :: struct {
	list:     ^wl.Ext_Foreign_Toplevel_List_V1,
	src_mgr:  ^wl.Ext_Foreign_Toplevel_Image_Capture_Source_Manager_V1,
	copy_mgr: ^wl.Ext_Image_Copy_Capture_Manager_V1,
	handles:  [dynamic]^Handle,
	enabled:  bool,
	timer:    linux.Fd,
	armed:    bool,
	next:     int,
	busy:     bool,
	job:      Job,
	failures: int,
}

SHM_ARGB8888 :: 0
SHM_XRGB8888 :: 1
SHM_XBGR8888 :: 0x34324258
SHM_ABGR8888 :: 0x34324241

// ---------------------------------------------------------------- the windows

handle_listener := wl.Ext_Foreign_Toplevel_Handle_V1_Listener {
	closed = proc "c" (data: rawptr, self: ^wl.Ext_Foreign_Toplevel_Handle_V1) {
		context = G.ctx
		h := cast(^Handle)data
		for x, i in G.cap.handles {
			if x == h {
				ordered_remove(&G.cap.handles, i)
				break
			}
		}
		wl.ext_foreign_toplevel_handle_v1_destroy(self)
		delete(h.title)
		delete(h.app_id)
		free(h)
	},
	done = proc "c" (data: rawptr, self: ^wl.Ext_Foreign_Toplevel_Handle_V1) {
		(cast(^Handle)data).done = true
	},
	title = proc "c" (data: rawptr, self: ^wl.Ext_Foreign_Toplevel_Handle_V1, title: cstring) {
		context = G.ctx
		h := cast(^Handle)data
		delete(h.title)
		h.title = strings.clone(string(title))
	},
	app_id = proc "c" (data: rawptr, self: ^wl.Ext_Foreign_Toplevel_Handle_V1, app_id: cstring) {
		context = G.ctx
		h := cast(^Handle)data
		delete(h.app_id)
		h.app_id = strings.clone(string(app_id))
	},
	identifier = proc "c" (data: rawptr, self: ^wl.Ext_Foreign_Toplevel_Handle_V1, identifier: cstring) {},
}

list_listener := wl.Ext_Foreign_Toplevel_List_V1_Listener {
	toplevel = proc "c" (data: rawptr, self: ^wl.Ext_Foreign_Toplevel_List_V1, t: ^wl.Ext_Foreign_Toplevel_Handle_V1) {
		context = G.ctx
		h := new(Handle)
		h.h = t
		append(&G.cap.handles, h)
		wl.ext_foreign_toplevel_handle_v1_add_listener(t, &handle_listener, h)
	},
	finished = proc "c" (data: rawptr, self: ^wl.Ext_Foreign_Toplevel_List_V1) {},
}

/// called for every global the registry announces
capture_global :: proc(r: ^wl.Wl_Registry, name: u32, iface: string, version: u32) {
	if env("IRIS_SHELL_CAPTURE") == "0" do return
	switch iface {
	case "ext_foreign_toplevel_list_v1":
		G.cap.list = cast(^wl.Ext_Foreign_Toplevel_List_V1)wl.wl_registry_bind(r, name, &wl.ext_foreign_toplevel_list_v1_interface, 1)
		wl.ext_foreign_toplevel_list_v1_add_listener(G.cap.list, &list_listener, nil)
	case "ext_foreign_toplevel_image_capture_source_manager_v1":
		G.cap.src_mgr = cast(^wl.Ext_Foreign_Toplevel_Image_Capture_Source_Manager_V1)wl.wl_registry_bind(r, name, &wl.ext_foreign_toplevel_image_capture_source_manager_v1_interface, 1)
	case "ext_image_copy_capture_manager_v1":
		G.cap.copy_mgr = cast(^wl.Ext_Image_Copy_Capture_Manager_V1)wl.wl_registry_bind(r, name, &wl.ext_image_copy_capture_manager_v1_interface, 1)
	}
}

/// after the first round trips: is everything there?
capture_start :: proc() {
	c := &G.cap
	c.enabled = c.list != nil && c.src_mgr != nil && c.copy_mgr != nil && G.shm != nil
	logf("window capture: %s", c.enabled ? "the compositor offers it" : "not offered (colours come from app id and title)")
}

// ---------------------------------------------------------------- the timer

/// windows that are on screen and that the compositor lists too
@(private="file") candidates :: proc(out: ^[logic.MAX_HALOS * 2]u64) -> int {
	n := 0
	seen: [dynamic]u64
	defer delete(seen)
	for o in G.outputs {
		f := output_target(o)
		for i in 0 ..< f.n {
			id := f.halos[i].id
			dup := false
			for s in seen do if s == id do dup = true
			if dup || n >= len(out) do continue
			append(&seen, id)
			out[n] = id
			n += 1
		}
	}
	return n
}

/// the timer runs only while there is a window to look at
cap_refresh :: proc() {
	c := &G.cap
	if !c.enabled do return
	ids: [logic.MAX_HALOS * 2]u64
	want := candidates(&ids) > 0
	if want == c.armed do return
	if c.timer < 0 {
		fd, err := linux.timerfd_create(.MONOTONIC, {.CLOEXEC, .NONBLOCK})
		if err != .NONE {
			c.enabled = false
			return
		}
		c.timer = fd
	}
	spec: linux.ITimer_Spec
	if want {
		spec.interval = {time_sec = 0, time_nsec = SAMPLE_MS * 1_000_000}
		spec.value = spec.interval
	}
	linux.timerfd_settime(c.timer, {}, &spec, nil)
	c.armed = want
}

capture_tick :: proc() {
	c := &G.cap
	buf: [8]u8
	linux.read(c.timer, buf[:])
	if !c.enabled || c.busy do return
	ids: [logic.MAX_HALOS * 2]u64
	n := candidates(&ids)
	if n == 0 do return
	c.next = (c.next + 1) % n
	i := logic.model_find(&G.model, ids[c.next])
	if i < 0 do return
	w := G.model.windows[i]
	for h in c.handles {
		if h.done && h.app_id == w.app_id && h.title == w.title {
			job_start(w.id, h)
			return
		}
	}
}

// ---------------------------------------------------------------- one capture

session_listener := wl.Ext_Image_Copy_Capture_Session_V1_Listener {
	buffer_size = proc "c" (data: rawptr, self: ^wl.Ext_Image_Copy_Capture_Session_V1, width, height: u32) {
		G.cap.job.w, G.cap.job.h = width, height
	},
	shm_format = proc "c" (data: rawptr, self: ^wl.Ext_Image_Copy_Capture_Session_V1, format: u32) {
		j := &G.cap.job
		switch format {
		case SHM_ARGB8888, SHM_XRGB8888, SHM_XBGR8888, SHM_ABGR8888:
			if !j.have_fmt {
				j.format, j.have_fmt = format, true
			}
		}
	},
	dmabuf_device = proc "c" (data: rawptr, self: ^wl.Ext_Image_Copy_Capture_Session_V1, device: ^wl.Array) {},
	dmabuf_format = proc "c" (data: rawptr, self: ^wl.Ext_Image_Copy_Capture_Session_V1, format: u32, modifiers: ^wl.Array) {},
	done = proc "c" (data: rawptr, self: ^wl.Ext_Image_Copy_Capture_Session_V1) {
		context = G.ctx
		j := &G.cap.job
		if j.frame != nil do return // the constraints came again: the frame is on its way
		if !j.have_fmt || j.w == 0 || j.h == 0 {
			job_fail("no shared-memory format offered")
			return
		}
		j.stride = j.w * 4
		j.size = uint(j.stride) * uint(j.h)
		if j.size > MAX_CAPTURE_BYTES {
			job_fail("window too large")
			return
		}
		fd, err := linux.memfd_create("iris-shell-capture", {.CLOEXEC})
		if err != .NONE {
			job_fail("memfd")
			return
		}
		defer linux.close(fd)
		if linux.ftruncate(fd, i64(j.size)) != .NONE {
			job_fail("ftruncate")
			return
		}
		mem, merr := linux.mmap(0, j.size, {.READ}, {.SHARED}, fd, 0)
		if merr != .NONE {
			job_fail("mmap")
			return
		}
		j.mem = mem
		pool := wl.wl_shm_create_pool(G.shm, i32(fd), i32(j.size))
		j.buffer = wl.wl_shm_pool_create_buffer(pool, 0, i32(j.w), i32(j.h), i32(j.stride), j.format)
		wl.wl_shm_pool_destroy(pool)
		j.frame = wl.ext_image_copy_capture_session_v1_create_frame(self)
		wl.ext_image_copy_capture_frame_v1_add_listener(j.frame, &frame_cap_listener, nil)
		wl.ext_image_copy_capture_frame_v1_attach_buffer(j.frame, j.buffer)
		wl.ext_image_copy_capture_frame_v1_damage_buffer(j.frame, 0, 0, i32(j.w), i32(j.h))
		wl.ext_image_copy_capture_frame_v1_capture(j.frame)
	},
	stopped = proc "c" (data: rawptr, self: ^wl.Ext_Image_Copy_Capture_Session_V1) {
		context = G.ctx
		job_fail("session stopped")
	},
}

job_start :: proc(win_id: u64, h: ^Handle) {
	c := &G.cap
	c.job = {win_id = win_id}
	c.busy = true
	c.job.source = wl.ext_foreign_toplevel_image_capture_source_manager_v1_create_source(c.src_mgr, h.h)
	c.job.session = wl.ext_image_copy_capture_manager_v1_create_session(c.copy_mgr, c.job.source, 0)
	wl.ext_image_copy_capture_session_v1_add_listener(c.job.session, &session_listener, nil)
}

job_end :: proc() {
	j := &G.cap.job
	if j.frame != nil do wl.ext_image_copy_capture_frame_v1_destroy(j.frame)
	if j.buffer != nil do wl.wl_buffer_destroy(j.buffer)
	if j.session != nil do wl.ext_image_copy_capture_session_v1_destroy(j.session)
	if j.source != nil do wl.ext_image_capture_source_v1_destroy(j.source)
	if j.mem != nil do linux.munmap(j.mem, j.size)
	j^ = {}
	G.cap.busy = false
}

job_fail :: proc(why: string) {
	c := &G.cap
	job_end()
	c.failures += 1
	debugf("capture failed: %s (%d)", why, c.failures)
	if c.failures >= 3 {
		c.enabled = false
		logf("window capture switched off after %d failures (last: %s)", c.failures, why)
		if c.armed && c.timer >= 0 {
			spec: linux.ITimer_Spec
			linux.timerfd_settime(c.timer, {}, &spec, nil)
			c.armed = false
		}
	}
}

frame_cap_listener := wl.Ext_Image_Copy_Capture_Frame_V1_Listener {
	transform = proc "c" (data: rawptr, self: ^wl.Ext_Image_Copy_Capture_Frame_V1, t: u32) {},
	damage = proc "c" (data: rawptr, self: ^wl.Ext_Image_Copy_Capture_Frame_V1, x, y, w, h: i32) {},
	presentation_time = proc "c" (data: rawptr, self: ^wl.Ext_Image_Copy_Capture_Frame_V1, hi, lo, ns: u32) {},
	ready = proc "c" (data: rawptr, self: ^wl.Ext_Image_Copy_Capture_Frame_V1) {
		context = G.ctx
		j := &G.cap.job
		mean, ok := sample_mean(j)
		id := j.win_id
		job_end()
		G.cap.failures = 0
		if !ok do return
		logic.model_set_sampled(&G.model, id, logic.tint_from_mean(mean))
		refresh_all()
	},
	failed = proc "c" (data: rawptr, self: ^wl.Ext_Image_Copy_Capture_Frame_V1, reason: u32) {
		context = G.ctx
		job_fail("the compositor could not copy the window")
	},
}

/// a 24 × 24 grid of pixels, the colourful ones counting more (so a page
/// that is mostly white around one picture reflects the picture)
sample_mean :: proc(j: ^Job) -> (mean: logic.Rgb, ok: bool) {
	if j.mem == nil || j.w == 0 || j.h == 0 do return
	px := ([^]u8)(j.mem)
	swap := j.format == SHM_XBGR8888 || j.format == SHM_ABGR8888
	GRID :: 24
	sum: logic.Rgb
	total: f32
	for gy in 0 ..< GRID {
		y := (u32(gy) * 2 + 1) * j.h / (GRID * 2)
		for gx in 0 ..< GRID {
			x := (u32(gx) * 2 + 1) * j.w / (GRID * 2)
			o := uint(y) * uint(j.stride) + uint(x) * 4
			b, g, r := f32(px[o]) / 255, f32(px[o + 1]) / 255, f32(px[o + 2]) / 255
			if swap do r, b = b, r
			wgt := max(r, g, b) - min(r, g, b) + 0.02
			sum += {r, g, b} * wgt
			total += wgt
		}
	}
	return sum / total, true
}
