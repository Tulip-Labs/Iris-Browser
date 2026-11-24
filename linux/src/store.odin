// Where Iris keeps things: ~/.local/share/iris (settings, history, the
// session, containers, compiled shields) and ~/.cache/iris; inside the
// Flatpak these are the app's own folders. Files are JSON, written through
// a temporary file so a crash never leaves half of one.
package iris

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:testing"
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
			// an empty or relative folder would put files where Iris started
			if !strings.has_prefix(v, "/") do break
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

/// writes a file whole, through a temporary one that reaches the disk
/// before it takes the file's place (a power cut leaves the old file or the
/// new one, never an empty one). Readable by you alone: your history and
/// session are nobody else's.
write_file :: proc(path: string, data: []u8) -> bool {
	make_dirs(filepath.dir(path))
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	f, err := os.open(tmp, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, {.Read_User, .Write_User})
	if err != nil do return false
	_, werr := os.write(f, data)
	if werr == nil do werr = os.sync(f)
	if cerr := os.close(f); werr == nil do werr = cerr
	if werr != nil {
		os.remove(tmp)
		return false
	}
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
		if len(title) > 0 do set_str(&v.title, title)
		history_later()
		return
	}
	append(&history, Visit{url = strings.clone(url), title = strings.clone(title), visits = 1, last = t})
	history_trim(&history, t)
	history_later()
}

HISTORY_MAX :: 3000
HISTORY_KEEP :: 2500

/// past HISTORY_MAX visits, the ones you are least likely to want again go
/// (the same score the suggestions use: often, and lately), and their
/// memory with them
history_trim :: proc(h: ^[dynamic]Visit, now: f64) {
	if len(h) <= HISTORY_MAX do return
	Ranked :: struct {
		v: Visit,
		s: f64,
	}
	r := make([]Ranked, len(h), context.temp_allocator)
	for v, i in h do r[i] = {v, score(v, now)}
	slice.stable_sort_by(r, proc(a, b: Ranked) -> bool { return a.s > b.s })
	for x, i in r {
		if i < HISTORY_KEEP {
			h[i] = x.v
		} else {
			delete(x.v.url)
			delete(x.v.title)
		}
	}
	resize(h, HISTORY_KEEP)
}

history_title :: proc(url, title: string) {
	history_ensure()
	if len(title) == 0 do return
	for &v in history do if v.url == url {
		// a page that keeps changing its title (a chat, a timer) no longer
		// leaves a copy of every one behind
		if v.title == title do return
		set_str(&v.title, title)
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

// ---------------------------------------------------------------- tests

@(test) test_history_trim :: proc(t: ^testing.T) {
	h := make([dynamic]Visit)
	defer {
		for v in h {
			delete(v.url)
			delete(v.title)
		}
		delete(h)
	}
	now := 1_000_000_000.0
	for i in 0 ..< HISTORY_MAX + 1 {
		// one visit each, a day older each time; the last is visited often
		append(&h, Visit{url = fmt.aprintf("https://e.com/%d", i), title = strings.clone("t"), visits = 1, last = now - f64(i) * 86400})
	}
	h[HISTORY_MAX].visits = 500
	history_trim(&h, now)
	testing.expect_value(t, len(h), HISTORY_KEEP)
	testing.expect_value(t, h[0].url, fmt.tprintf("https://e.com/%d", HISTORY_MAX))
	testing.expect_value(t, h[1].url, "https://e.com/0")
}
