// Iris Shields: ad and tracker blocking inside the engine. uBlock Origin's
// and EasyList's lists (fetched every four days from uBlock's mirrors) are
// turned into WebKit content rules on a thread, compiled by WebKit once and
// kept; until then, about 100,000 ad and tracker domains built into Iris
// stand in.
package iris

import "base:runtime"
import "core:compress/deflate"
import "core:fmt"
import "core:log"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"

VERSION :: "2.2.4"
// the Flatpak's ID: the window's app_id, and the name WebKit gives its sandboxed processes
APP_ID :: "io.github.tulip_labs.Iris"
USER_AGENT :: "Iris/" + VERSION

@(private="file") DOMAINS_GZ :: #load("shield-domains.txt.gz")
@(private="file") domain_list: []string

/// the built-in ad and tracker domains, sorted (inflated on first use)
shield_domains :: proc() -> []string {
	if domain_list != nil do return domain_list
	// kept for the whole run: from the heap itself, not a caller's allocator
	context.allocator = runtime.heap_allocator()
	out: [dynamic]u8
	if deflate.inflate_gzip(&out, DOMAINS_GZ) != nil do return nil
	text := string(out[:])
	list := make([dynamic]string, 0, 110_000)
	t := text
	for line in strings.split_lines_iterator(&t) do if len(line) > 0 do append(&list, line)
	domain_list = list[:]
	return domain_list
}

host_blocked :: proc(h: string) -> bool {
	return listed(shield_domains(), h)
}

/// is the shield up for this host?
shields_on_for :: proc(host: string) -> bool {
	s := settings()
	if !s.shields do return false
	if len(host) == 0 do return true
	return !shields_off_for(site_of(host))
}

shield_level :: proc() -> Level {
	return settings().shieldLevel
}

Shields :: struct {
	filters:     [dynamic]^WebKitUserContentFilter,
	waiting:     [dynamic]^WebKitUserContentManager,
	store:       ^WebKitUserContentFilterStore,
	dir:         string,
	building:    Maybe(Level),
	fetch_tried: [Level]bool,
	session:     ^SoupSession,
	/// a new set of rules is in place: pages already open take it
	installed:   proc(),
}

shields: Shields

shields_start :: proc() {
	shields.dir = join({cache_dir(), "shields"})
	make_dirs(join({shields.dir, "lists"}, context.temp_allocator))
	shields.store = webkit_user_content_filter_store_new(cstr(shields.dir))
	shields_load(shield_level())
	after(8000, proc(_: rawptr) { refresh_lists() }, nil)
}

shields_level_changed :: proc() {
	shields_load(shield_level())
}

shields_ready :: proc() -> bool {
	return len(shields.filters) > 0
}

@(private="file") ids_path :: proc(l: Level) -> string {
	return fmt.tprintf("%s/%v.ids", shields.dir, l)
}

@(private="file") list_file :: proc(l: List, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%s/lists/%s.txt", shields.dir, list_id(l), allocator = allocator)
}

// ---------------------------------------------------------------- loading what was compiled before

@(private="file") Load :: struct {
	l:      Level,
	got:    []^WebKitUserContentFilter,
	left:   int,
	failed: bool,
}

@(private="file") Load_One :: struct {
	job: ^Load,
	i:   int,
}

@(private="file") shields_load :: proc(l: Level) {
	if p := env("IRIS_SHIELDS_JSON"); len(p) > 0 {
		if j, ok := read_file(p); ok {
			parts := []string{string(j)}
			shields_compile(parts, l)
			return
		}
	}
	text, ok := read_file(ids_path(l), context.temp_allocator)
	if !ok {
		shields_build(l)
		return
	}
	ids := strings.split_lines(strings.trim_space(string(text)), context.temp_allocator)
	if len(ids) == 0 || ids[0] == "" {
		shields_build(l)
		return
	}
	job := new(Load)
	job^ = {l = l, got = make([]^WebKitUserContentFilter, len(ids)), left = len(ids)}
	for id, i in ids {
		one := new(Load_One)
		one^ = {job, i}
		webkit_user_content_filter_store_load(shields.store, cstr(id), nil, rawptr(loaded), one)
	}
}

@(private="file") loaded :: proc "c" (o: ^GObject, res: ^GAsyncResult, d: rawptr) {
	context = main_context
	one := cast(^Load_One)d
	job := one.job
	free(one)
	err: ^GError
	f := webkit_user_content_filter_store_load_finish(cast(^WebKitUserContentFilterStore)o, res, &err)
	if err != nil do g_error_free(err)
	job.got[one.i] = f
	if f == nil do job.failed = true
	job.left -= 1
	if job.left > 0 do return
	defer {
		delete(job.got)
		free(job)
	}
	if job.failed {
		for g in job.got do if g != nil do webkit_user_content_filter_unref(g)
		shields_build(job.l)
	} else {
		shields_install(job.got, job.l)
	}
}

// ---------------------------------------------------------------- building: lists -> rules, on a thread

@(private="file") Build :: struct {
	l:     Level,
	paths: [dynamic]string,
	arena: virtual.Arena,
	parts: []string,
}

@(private="file") shields_build :: proc(l: Level) {
	if _, busy := shields.building.?; busy do return
	missing: [dynamic]List
	defer delete(missing)
	for li in level_lists(l) do if !os.exists(list_file(li)) do append(&missing, li)
	if len(missing) > 0 && !shields.fetch_tried[l] {
		shields.fetch_tried[l] = true
		fetch(missing[:], l, false)
		return
	}
	shields.building = l
	job := new(Build)
	job.l = l
	for li in level_lists(l) do append(&job.paths, list_file(li, context.allocator))
	thread.create_and_start_with_poly_data(job, proc(job: ^Build) {
		_ = virtual.arena_init_growing(&job.arena)
		context.allocator = virtual.arena_allocator(&job.arena)
		conv := Converter{level = job.l}
		any := false
		for p in job.paths {
			t := read_file(p) or_continue
			converter_add_list(&conv, string(t))
			any = true
		}
		if !any do converter_add_domains(&conv, shield_domains())
		max_rules := 120_000
		if v, ok := strconv.parse_int(os.get_env("IRIS_SHIELDS_PART", context.temp_allocator)); ok do max_rules = v
		job.parts = converter_finish(&conv, max_rules)
		context.allocator = main_context.allocator
		idle(proc(d: rawptr) {
			job := cast(^Build)d
			shields.building = nil
			shields_compile(job.parts, job.l)
			for p in job.paths do delete(p)
			delete(job.paths)
			virtual.arena_destroy(&job.arena)
			free(job)
		}, job)
	}, init_context = main_context, self_cleanup = true)
}

// ---------------------------------------------------------------- compiling: rules -> WebKit's filters

@(private="file") Compile :: struct {
	l:    Level,
	ids:  []string,
	got:  []^WebKitUserContentFilter,
	left: int,
}

@(private="file") shields_compile :: proc(parts: []string, l: Level) {
	if len(parts) == 0 do return
	job := new(Compile)
	stamp := time.to_unix_seconds(time.now())
	job^ = {l = l, ids = make([]string, len(parts)), got = make([]^WebKitUserContentFilter, len(parts)), left = len(parts)}
	shields.building = l
	for json, i in parts {
		job.ids[i] = fmt.aprintf("iris-%v-%d-%d", l, stamp, i)
		b := g_bytes_new(raw_data(json), len(json))
		one := new(Load_One)
		one^ = {cast(^Load)job, i}
		webkit_user_content_filter_store_save(shields.store, cstr(job.ids[i]), b, nil, rawptr(saved), one)
		g_bytes_unref(b)
	}
}

@(private="file") saved :: proc "c" (o: ^GObject, res: ^GAsyncResult, d: rawptr) {
	context = main_context
	one := cast(^Load_One)d
	job := cast(^Compile)one.job
	i := one.i
	free(one)
	err: ^GError
	f := webkit_user_content_filter_store_save_finish(cast(^WebKitUserContentFilterStore)o, res, &err)
	if err != nil {
		log.warnf("the shield's rules did not compile: %s", err.message)
		g_error_free(err)
	}
	job.got[i] = f
	job.left -= 1
	if job.left > 0 do return
	shields.building = nil
	defer {
		for id in job.ids do delete(id)
		delete(job.ids)
		delete(job.got)
		free(job)
	}
	for g in job.got do if g == nil {
		for x in job.got do if x != nil do webkit_user_content_filter_unref(x)
		return
	}
	// the parts compiled before go
	if old, ok := read_file(ids_path(job.l), context.temp_allocator); ok {
		s := string(old)
		outer: for id in strings.split_lines_iterator(&s) {
			for n in job.ids do if n == id do continue outer
			webkit_user_content_filter_store_remove(shields.store, cstr(id), nil, nil, nil)
		}
	}
	write_file(ids_path(job.l), transmute([]u8)strings.join(job.ids, "\n", context.temp_allocator))
	shields_install(job.got, job.l)
}

@(private="file") shields_install :: proc(made: []^WebKitUserContentFilter, l: Level) {
	if l != shield_level() {
		for m in made do if m != nil do webkit_user_content_filter_unref(m)
		return
	}
	for f in shields.filters do webkit_user_content_filter_unref(f)
	clear(&shields.filters)
	for m in made do if m != nil do append(&shields.filters, m)
	for ucm in shields.waiting do for f in shields.filters do webkit_user_content_manager_add_filter(ucm, f)
	clear(&shields.waiting)
	if shields.installed != nil do shields.installed()
}

// ---------------------------------------------------------------- the lists, from uBlock's mirrors

@(private="file") refresh_lists :: proc() {
	old: [dynamic]List
	defer delete(old)
	now := time.now()
	for li in level_lists(shield_level()) {
		fi, err := os.stat(list_file(li), context.temp_allocator)
		if err != nil || time.diff(fi.modification_time, now) > 4 * 24 * time.Hour do append(&old, li)
	}
	if len(old) > 0 do fetch(old[:], shield_level(), true)
}

@(private="file") Fetch :: struct {
	l:           Level,
	rebuild_all: bool,
	left:        int,
}

@(private="file") Get :: struct {
	fetch:  ^Fetch,
	list:   List,
	mirror: int,
	msg:    ^SoupMessage,
}

@(private="file") fetch :: proc(lists: []List, l: Level, rebuild_all: bool) {
	if shields.session == nil do shields.session = soup_session_new()
	f := new(Fetch)
	f^ = {l = l, rebuild_all = rebuild_all, left = len(lists)}
	for li in lists {
		g := new(Get)
		g^ = {fetch = f, list = li}
		get(g)
	}
}

@(private="file") get :: proc(g: ^Get) {
	mirrors := LIST_MIRRORS
	if g.mirror >= len(mirrors) {
		got_list(g, nil)
		return
	}
	msg := soup_message_new("GET", cstr(strings.concatenate({mirrors[g.mirror], list_path(g.list)}, context.temp_allocator)))
	if msg == nil {
		g.mirror += 1
		get(g)
		return
	}
	soup_message_headers_append(soup_message_get_request_headers(msg), "User-Agent", USER_AGENT)
	g.msg = msg
	soup_session_send_and_read_async(shields.session, msg, 300, nil, rawptr(answered), g)
}

@(private="file") answered :: proc "c" (o: ^GObject, res: ^GAsyncResult, d: rawptr) {
	context = main_context
	g := cast(^Get)d
	err: ^GError
	b := soup_session_send_and_read_finish(cast(^SoupSession)o, res, &err)
	if err != nil do g_error_free(err)
	status := soup_message_get_status(g.msg)
	unref(g.msg)
	g.msg = nil
	if b != nil {
		defer g_bytes_unref(b)
		n: uint
		p := g_bytes_get_data(b, &n)
		if status == 200 && p != nil {
			got_list(g, ([^]u8)(p)[:n])
			return
		}
	}
	g.mirror += 1
	get(g)
}

@(private="file") got_list :: proc(g: ^Get, data: []u8) {
	f := g.fetch
	// a real list starts with its header (! or [Adblock)
	if len(data) > 1000 && (data[0] == '!' || data[0] == '[') do write_file(list_file(g.list), data)
	free(g)
	f.left -= 1
	if f.left > 0 do return
	l, rebuild := f.l, f.rebuild_all
	free(f)
	if rebuild do for other in Level do if other != shield_level() do os.remove(ids_path(other))
	shields_build(l)
}

// ---------------------------------------------------------------- pages

/// a page takes the shield's rules (none where the shield is down)
shields_apply :: proc(ucm: ^WebKitUserContentManager, host: string) {
	webkit_user_content_manager_remove_all_filters(ucm)
	shields_forget(ucm)
	if !shields_on_for(host) do return
	if len(shields.filters) == 0 {
		append(&shields.waiting, ucm)
	} else {
		for f in shields.filters do webkit_user_content_manager_add_filter(ucm, f)
	}
}

shields_forget :: proc(ucm: ^WebKitUserContentManager) {
	for i := 0; i < len(shields.waiting); {
		if shields.waiting[i] == ucm { unordered_remove(&shields.waiting, i) } else { i += 1 }
	}
}

@(test) test_builtin_domains :: proc(t: ^testing.T) {
	testing.expect(t, len(shield_domains()) > 50_000)
	testing.expect(t, !host_blocked("example.com"))
	testing.expect(t, host_blocked(shield_domains()[100]))
}
