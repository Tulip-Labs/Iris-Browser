// What both engines share around the pages: the containers' list, the
// scripts pages get, and the downloads' list (the engines' own parts:
// wpe_engine.odin, cef_engine.odin).
package iris

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/linux"
import "core:testing"
import "core:time"
import "core:unicode/utf8"

// ---------------------------------------------------------------- the engine

memory_mb :: proc() -> u64 {
	info: linux.Sys_Info
	if linux.sysinfo(&info) != .NONE do return 8192
	return u64(info.totalram) * u64(max(1, info.mem_unit)) / (1 << 20)
}

LIGHT_VIDEO :: `(() => {
  const heavy = /vp0?9|vp8|av01/i;
  for (const MS of [window.MediaSource, window.ManagedMediaSource]) {
    if (MS && MS.isTypeSupported) {
      const ok = MS.isTypeSupported.bind(MS);
      MS.isTypeSupported = t => heavy.test(t) ? false : ok(t);
    }
  }
  const can = HTMLMediaElement.prototype.canPlayType;
  HTMLMediaElement.prototype.canPlayType = function (t) { return heavy.test(t) ? '' : can.call(this, t); };
})();`

/// YouTube with no ads and nothing for it to notice (the same file as Iris
/// for Android's)
YOUTUBE :: #load("youtube.js", string)

/// a page left unable to scroll by a cookie notice the shield hid (the
/// notice set overflow: hidden on the page, and only its own button undoes
/// it): scrolling comes back when the page is taller than the window and
/// nothing fixed sits over its middle. Web apps that scroll inside
/// themselves are exactly the window's height, and stay as they are.
SCROLL_UNLOCK :: `(() => {
  const fix = () => {
    const x = innerWidth / 2, y = innerHeight / 2;
    for (let n = document.elementFromPoint(x, y); n && n !== document.body && n !== document.documentElement; n = n.parentElement) {
      const p = getComputedStyle(n).position;
      if (p === 'fixed' || p === 'sticky') return;
    }
    for (const e of [document.documentElement, document.body]) {
      if (!e || getComputedStyle(e).overflowY !== 'hidden') continue;
      if (document.documentElement.scrollHeight < innerHeight + 80) continue;
      e.style.setProperty('overflow', 'auto', 'important');
    }
  };
  const later = () => { setTimeout(fix, 1500); setTimeout(fix, 5000); };
  if (document.readyState === 'complete') later(); else addEventListener('load', later, { once: true });
})();`

/// what Google search, AI Mode and YouTube load first: looked up (and the
/// first few connected) before you need them. Only these: nothing else is
/// looked up or loaded ahead.
GOOGLE_HOSTS :: [?]string{
	"www.google.com", "www.gstatic.com", "ssl.gstatic.com", "fonts.gstatic.com", "apis.google.com",
	"encrypted-tbn0.gstatic.com", "lh3.googleusercontent.com", "play.google.com",
	"www.youtube.com", "m.youtube.com", "i.ytimg.com", "yt3.ggpht.com", "redirector.googlevideo.com",
}
/// the hosts worth a whole connection (TCP and TLS) ahead: the page and its
/// first scripts and images
GOOGLE_PRECONNECT :: `(() => {
  for (const h of ['https://www.google.com', 'https://www.gstatic.com', 'https://www.youtube.com', 'https://i.ytimg.com']) {
    const l = document.createElement('link');
    l.rel = 'preconnect';
    l.href = h;
    (document.head || document.documentElement).appendChild(l);
    l.remove();
  }
})();`

// ---------------------------------------------------------------- containers

Container :: struct {
	id:    string,
	name:  string,
	color: string,
	icon:  string,
}

PRIVATE_ID :: "private"
/// the colours a container can have (no purple): blue, teal, green,
/// yellow, orange, red, pink, graphite
PALETTE :: [?]string{"#0a84ff", "#30b0c7", "#30d158", "#ffd60a", "#ff9f0a", "#ff453a", "#ff6482", "#8e8e93"}

containers: [dynamic]Container
@(private="file") containers_loaded: bool
new_id :: proc() -> string {
	b: [16]u8
	linux.getrandom(b[:], {})
	// 32 hex digits ("%x" on the array wrote "[1f, a, ...]")
	sb := strings.builder_make()
	for x in b do fmt.sbprintf(&sb, "%02x", x)
	return strings.to_string(sb)
}

containers_ensure :: proc() {
	if containers_loaded do return
	containers_loaded = true
	// none to begin with: you make the ones you want
	if l, ok := load_json([dynamic]Container, "containers.json"); ok do containers = l
}

@(private="file") containers_save :: proc() {
	save_json("containers.json", containers[:])
}

container_get :: proc(id: string) -> (Container, bool) {
	containers_ensure()
	if id == "" do return {}, false
	if id == PRIVATE_ID do return {PRIVATE_ID, "Private", "#636366", "private"}, true
	for k in containers do if k.id == id do return k, true
	return {}, false
}

/// a container's id as Iris makes them (hex; before 2.2.4 the bytes were
/// written as a list, "[1f, a, ...]"): anything else in containers.json
/// never names a folder
valid_container_id :: proc(id: string) -> bool {
	if len(id) == 0 || len(id) > 128 do return false
	for c in transmute([]u8)id {
		ok := (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || c == '[' || c == ']' || c == ',' || c == ' '
		if !ok do return false
	}
	return true
}

/// a new container, named and in one of PALETTE's colours ("" for the
/// first one no container has yet)
container_add :: proc(name, color0: string) -> Container {
	containers_ensure()
	p := PALETTE
	color := color0
	if len(color) == 0 {
		color = p[len(containers) % len(p)]
		outer: for c in p {
			for k in containers do if k.color == c do continue outer
			color = c
			break
		}
	}
	k := Container{new_id(), strings.clone(name), strings.clone(color), "dot"}
	append(&containers, k)
	containers_save()
	return k
}

/// a container and everything its sites kept, gone
container_remove :: proc(id: string) {
	for i := 0; i < len(containers); {
		if containers[i].id == id { ordered_remove(&containers, i) } else { i += 1 }
	}
	containers_save()
	// the engine drops the container's world and the files it kept
	engine_forget_container(id)
}

// ---------------------------------------------------------------- downloads

Download :: struct {
	/// the engine's handle on it (wpe_engine.odin, cef_engine.odin)
	using engine: Download_Engine,
	id:        int,
	name:      string,
	path:      string,
	progress:  f64,
	received:  u64,
	done:      bool,
	failed:    bool,
	cancelled: bool,
}

downloads: [dynamic]^Download
/// a download started, moved on or ended
downloads_changed: proc(d: ^Download)
next_download := 1

download_status :: proc(d: ^Download) -> string {
	if d.failed do return d.cancelled ? "Cancelled" : "Failed"
	if d.done do return format_size(d.received)
	if d.progress > 0.001 {
		return fmt.tprintf("%s of %s", format_size(d.received), format_size(u64(f64(d.received) / d.progress)))
	}
	return format_size(d.received)
}

format_size :: proc(b: u64) -> string {
	switch {
	case b < 1000: return fmt.tprintf("%d bytes", b)
	case b < 1000_000: return fmt.tprintf("%.1f kB", f64(b) / 1e3)
	case b < 1000_000_000: return fmt.tprintf("%.1f MB", f64(b) / 1e6)
	}
	return fmt.tprintf("%.1f GB", f64(b) / 1e9)
}

downloads_active :: proc() -> int {
	n := 0
	for d in downloads do if !d.done && !d.failed do n += 1
	return n
}

@(private="file") taken :: proc(p: string) -> bool {
	if os.exists(p) do return true
	for d in downloads do if d.path == p && !d.failed do return true
	return false
}

/// the name a site suggests, made safe for the Downloads folder: no folders,
/// no control characters, not hidden, and short enough for the file system
/// (255 bytes), its extension kept
download_name :: proc(name: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(context.temp_allocator)
	for r in name {
		switch {
		case r == '/' || r == '\\': strings.write_byte(&b, '_')
		case r < 0x20 || r == 0x7f || r == 0xfffd: strings.write_byte(&b, '_')
		case: strings.write_rune(&b, r)
		}
	}
	clean := strings.trim(strings.to_string(b), " .")
	if clean == "" do return strings.clone("download", allocator)
	MAX :: 200 // room left for " (99)"
	if len(clean) > MAX {
		ext := filepath.ext(clean)
		if len(ext) > 16 do ext = ""
		keep := MAX - len(ext)
		// never cut a character in half
		for keep > 0 && (clean[keep] & 0xc0) == 0x80 do keep -= 1
		clean = strings.concatenate({clean[:keep], ext}, context.temp_allocator)
	}
	return strings.clone(clean, allocator)
}

/// a free name in the Downloads folder ("a.pdf", "a (2).pdf", ...)
unique_download :: proc(name: string) -> string {
	dir := downloads_dir()
	make_dirs(dir)
	base := download_name(name)
	ext := filepath.ext(base)
	stem := base[:len(base) - len(ext)]
	p := join({dir, base})
	for n := 2; taken(p); n += 1 {
		delete(p)
		p = join({dir, fmt.tprintf("%s (%d)%s", stem, n, ext)})
	}
	return p
}

/// a download started, moved on or ended: the chrome shows it
download_changed :: proc(d: ^Download) {
	if downloads_changed != nil do downloads_changed(d)
}

downloads_clear_finished :: proc() {
	for i := 0; i < len(downloads); {
		d := downloads[i]
		if d.done || d.failed {
			ordered_remove(&downloads, i)
			download_release(d)
			free(d)
		} else {
			i += 1
		}
	}
}

/// opens a finished download with its app (xdg-open; the portal in Flatpak)
download_open :: proc(d: ^Download) {
	spawn({"xdg-open", d.path})
}

/// shows a download in the file manager
download_show :: proc(d: ^Download) {
	bus := g_bus_get_sync(G_BUS_TYPE_SESSION, nil, nil)
	if bus == nil {
		spawn({"xdg-open", filepath.dir(d.path)})
		return
	}
	uri := g_variant_new_string(cstr(file_uri(d.path, context.temp_allocator)))
	t := g_variant_type_new("s")
	arr := g_variant_new_array(t, &uri, 1)
	g_variant_type_free(t)
	args := [2]^GVariant{arr, g_variant_new_string("")}
	g_dbus_connection_call(bus, "org.freedesktop.FileManager1", "/org/freedesktop/FileManager1", "org.freedesktop.FileManager1", "ShowItems", g_variant_new_tuple(&args[0], 2), nil, 0, -1, nil, nil, nil)
}

/// starts a program on its own (GLib reaps it)
spawn :: proc(argv: []string) {
	a := make([]cstring, len(argv) + 1, context.temp_allocator)
	for s, i in argv do a[i] = cstr(s)
	err: ^GError
	g_spawn_async(nil, &a[0], nil, 1 << 2, nil, nil, nil, &err) // SEARCH_PATH
	if err != nil do g_error_free(err)
}

@(private="file") _t :: time.Duration

// ---------------------------------------------------------------- tests

@(test) test_download_names :: proc(t: ^testing.T) {
	testing.expect_value(t, download_name("report.pdf"), "report.pdf")
	testing.expect_value(t, download_name("../../.bashrc"), "_.._.bashrc")
	testing.expect_value(t, download_name(".hidden"), "hidden")
	testing.expect_value(t, download_name("a\nb\x00c.txt"), "a_b_c.txt")
	testing.expect_value(t, download_name("dir\\file.zip"), "dir_file.zip")
	testing.expect_value(t, download_name(""), "download")
	testing.expect_value(t, download_name(" .. "), "download")
	long := strings.repeat("ñ", 150, context.temp_allocator) // 300 bytes
	n := download_name(strings.concatenate({long, ".tar.gz"}, context.temp_allocator))
	testing.expect(t, len(n) <= 200)
	testing.expect(t, strings.has_suffix(n, ".gz"))
	testing.expect(t, utf8.valid_string(n))
}

@(test) test_container_ids :: proc(t: ^testing.T) {
	id := new_id()
	defer delete(id)
	testing.expect_value(t, len(id), 32)
	testing.expect(t, valid_container_id(id))
	testing.expect(t, valid_container_id("[1, 2, 3, fa, 5, 6, 7, 8, 9, a, b, c, d, e, f, 10]"))
	testing.expect(t, !valid_container_id("../../.."))
	testing.expect(t, !valid_container_id("a/b"))
	testing.expect(t, !valid_container_id(""))
}
