// Where Iris keeps things: ~/.local/share/iris (settings, history, the
// session, containers, compiled shields) and ~/.cache/iris; inside the
// Flatpak these are the app's own folders. Files are JSON, written through
// a temporary file so a crash never leaves half of one.
package iris

import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"

env :: proc(k: string) -> string {
	return os.get_env(k, context.temp_allocator)
}

home_dir :: proc() -> string {
	h := env("HOME")
	return len(h) > 0 ? h : "/"
}

@(private="file") xdg :: proc(var, fallback: string) -> string {
	v := env(var)
	base := len(v) > 0 ? v : join({home_dir(), fallback}, context.temp_allocator)
	return join({base, "iris"})
}

data_dir :: proc() -> string {
	@(static) d: string
	if d == "" do d = xdg("XDG_DATA_HOME", ".local/share")
	return d
}

cache_dir :: proc() -> string {
	@(static) d: string
	if d == "" do d = xdg("XDG_CACHE_HOME", ".cache")
	return d
}

/// the Downloads folder (XDG_DOWNLOAD_DIR in user-dirs.dirs, else ~/Downloads)
downloads_dir :: proc() -> string {
	@(static) d: string
	if d != "" do return d
	cfg := env("XDG_CONFIG_HOME")
	if len(cfg) == 0 do cfg = join({home_dir(), ".config"}, context.temp_allocator)
	if text, ok := read_file(join({cfg, "user-dirs.dirs"}, context.temp_allocator), context.temp_allocator); ok {
		s := string(text)
		for line in strings.split_lines_iterator(&s) {
			if !strings.has_prefix(line, "XDG_DOWNLOAD_DIR=") do continue
			v := strings.trim(line[len("XDG_DOWNLOAD_DIR="):], "\" ")
			v, _ = strings.replace_all(v, "$HOME", home_dir(), context.temp_allocator)
			d = strings.clone(v)
			return d
		}
	}
	d = join({home_dir(), "Downloads"})
	return d
}

data_path :: proc(name: string, allocator := context.temp_allocator) -> string {
	return join({data_dir(), name}, allocator)
}

make_dirs :: proc(p: string) {
	if p != "" && !os.exists(p) do os.make_directory_all(p)
}

/// a whole file, or false
read_file :: proc(path: string, allocator := context.allocator) -> ([]u8, bool) {
	d, err := os.read_entire_file(path, allocator)
	return d, err == nil
}

/// path parts joined with /
join :: proc(parts: []string, allocator := context.allocator) -> string {
	s, _ := filepath.join(parts, allocator)
	return s
}

/// writes a file whole, through a temporary one
write_file :: proc(path: string, data: []u8) -> bool {
	make_dirs(filepath.dir(path))
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	if os.write_entire_file(tmp, data) != nil do return false
	return os.rename(tmp, path) == nil
}

load_json :: proc($T: typeid, name: string) -> (v: T, ok: bool) {
	data := read_file(data_path(name), context.temp_allocator) or_return
	err := json.unmarshal(data, &v)
	return v, err == nil
}

save_json :: proc(name: string, v: any) {
	data, err := json.marshal(v, {pretty = true}, context.temp_allocator)
	if err == nil do write_file(data_path(name), data)
}

now_s :: proc() -> f64 {
	return f64(time.now()._nsec) / 1e9
}

// ---------------------------------------------------------------- settings

Saved_Tab :: struct {
	url:       string,
	title:     string,
	container: string,
}

Settings :: struct {
	shields:           bool,
	/// sites where the shield is off
	shieldsOff:        [dynamic]string,
	/// the pages open when Iris last closed, to open again
	session:           [dynamic]Saved_Tab,
	lastUpdateCheck:   f64,
	/// YouTube sends H.264 instead of VP9 or AV1 (much lighter)
	lightVideo:        bool,
	/// how hard Shields block
	shieldLevel:       Level,
}

@(private="file") settings_value: Settings
@(private="file") settings_loaded: bool

settings :: proc() -> ^Settings {
	if !settings_loaded {
		settings_loaded = true
		settings_value = {shields = true, lightVideo = true, shieldLevel = .aggressive}
		if s, ok := load_json(Settings, "settings.json"); ok do settings_value = s
	}
	return &settings_value
}

settings_save :: proc() {
	save_json("settings.json", settings()^)
}

shields_off_for :: proc(site: string) -> bool {
	return slice.contains(settings().shieldsOff[:], site)
}

/// turns the shield off for a site, or back on
toggle_site :: proc(site: string) {
	s := settings()
	for x, i in s.shieldsOff do if x == site {
		ordered_remove(&s.shieldsOff, i)
		settings_save()
		return
	}
	append(&s.shieldsOff, strings.clone(site))
	settings_save()
}

// ---------------------------------------------------------------- history

/// The pages you have been to, for the address bar's suggestions. Private
/// and sandboxed tabs leave nothing here.
Visit :: struct {
	url:    string,
	title:  string,
	visits: u32,
	last:   f64,
}

@(private="file") history: [dynamic]Visit
@(private="file") history_loaded, history_dirty: bool

@(private="file") history_ensure :: proc() {
	if history_loaded do return
	history_loaded = true
	if v, ok := load_json([dynamic]Visit, "history.json"); ok do history = v
}

@(private="file") score :: proc(v: Visit, t: f64) -> f64 {
	days := max(0, t - v.last) / 86400
	return f64(v.visits) / (1 + days / 7)
}

history_record :: proc(url, title: string) {
	history_ensure()
	if !strings.has_prefix(url, "http") do return
	if _, ok := ai_query(url, context.temp_allocator); ok do return
	t := now_s()
	for &v in history do if v.url == url {
		v.visits += 1
		v.last = t
		if len(title) > 0 do v.title = strings.clone(title)
		history_later()
		return
	}
	append(&history, Visit{url = strings.clone(url), title = strings.clone(title), visits = 1, last = t})
	if len(history) > 3000 {
		ctx := t
		slice.sort_by(history[:], proc(a, b: Visit) -> bool { return a.visits * 1000 + u32(a.last / 86400) > b.visits * 1000 + u32(b.last / 86400) })
		_ = ctx
		resize(&history, 2500)
	}
	history_later()
}

history_title :: proc(url, title: string) {
	history_ensure()
	if len(title) == 0 do return
	for &v in history do if v.url == url {
		v.title = strings.clone(title)
		history_later()
		return
	}
}

@(private="file") history_later :: proc() {
	if history_dirty do return
	history_dirty = true
	after(2000, proc(_: rawptr) { history_flush() }, nil)
}

history_flush :: proc() {
	if !history_dirty do return
	history_dirty = false
	save_json("history.json", history[:])
}

/// the visits that match what was typed, best first
history_suggest :: proc(q0: string, n: int, allocator := context.temp_allocator) -> []Visit {
	history_ensure()
	q := strings.to_lower(strings.trim_space(q0), context.temp_allocator)
	if len(q) == 0 do return nil
	t := now_s()
	Scored :: struct {
		v: Visit,
		s: f64,
	}
	hits := make([dynamic]Scored, context.temp_allocator)
	for v in history {
		host := strings.to_lower(display_url(v.url, context.temp_allocator), context.temp_allocator)
		u := strings.to_lower(v.url, context.temp_allocator)
		ti := strings.to_lower(v.title, context.temp_allocator)
		s := 0.0
		if strings.has_prefix(host, q) {
			s = 4
		} else if strings.contains(u, q) {
			s = 2
		} else if strings.contains(ti, q) {
			s = 1.5
		}
		if s > 0 do append(&hits, Scored{v, s * (1 + score(v, t))})
	}
	slice.sort_by(hits[:], proc(a, b: Scored) -> bool { return a.s > b.s })
	out := make([]Visit, min(n, len(hits)), allocator)
	for &o, i in out do o = hits[i].v
	return out
}
