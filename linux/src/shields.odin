// Iris Shields: ad and tracker blocking inside the engine. uBlock Origin's
// and EasyList's lists (fetched every four days from uBlock's mirrors) are
// turned into rules on a thread (rules.odin): WebKit compiles them once
// into content rules and keeps them; CEF keeps them in a compact file of
// Iris's own (shield_match.odin) that later starts only read. About 185,000
// ad, tracker, fingerprinting and mining domains built into Iris
// (tools/shield-domains.sh) block from the first page: until the lists
// come, and at the ultra level, the default, on top of them.
package iris

import "base:runtime"
import "core:compress/deflate"
import "core:fmt"
import "core:hash"
import "core:log"
import "core:mem/virtual"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

VERSION :: "2.3.1"
// the Flatpak's ID: the window's app_id, and the name WebKit gives its sandboxed processes
APP_ID :: "io.github.tulip_labs.Iris" + APP_ID_ENGINE // (".Cef": the CEF build installs beside the WPE one)
USER_AGENT :: "Iris/" + BUILD_VERSION

@(private="file") DOMAINS_GZ :: #load("shield-domains.txt.gz")
@(private="file") builtin_once: sync.Once
@(private="file") builtin_text: string

/// the built-in ad and tracker domains: a host set (rules.odin), inflated
/// once and never changed (shields_start does it on the main thread; a
/// first caller anywhere else waits for it instead of racing it)
builtin_hosts :: proc() -> string {
	sync.once_do(&builtin_once, proc() {
		out := make([dynamic]u8, 0, 4 << 20, runtime.heap_allocator())
		if deflate.inflate_gzip(&out, DOMAINS_GZ) != nil do return
		builtin_text = strings.trim_right(string(out[:]), "\n")
	})
	return builtin_text
}

/// what the built-in list is (a cache made with another one is not read)
@(private="file") builtin_rev :: proc() -> u32 {
	@(static) rev: u32
	if rev == 0 do rev = hash.crc32(DOMAINS_GZ) | 1
	return rev
}

/// a host Iris's own list blocks (pop-ups, the privacy report)
host_blocked :: proc(h: string) -> bool {
	e, ok := set_find(builtin_hosts(), h)
	return ok && usable(e)
}

/// is the shield up for this host?
shields_on_for :: proc(host: string) -> bool {
	s := settings()
	if !s.shields do return false
	if len(host) == 0 do return true
	return !shields_off_for(site_of(host))
}

/// an address without its tracking parameters, where the shield is up for
/// its site (temporary; the address itself where there is nothing to take)
shields_clean_url :: proc(u: string) -> string {
	h, ok := host_of(u, context.temp_allocator)
	if !ok || !shields_on_for(h) do return u
	if clean, stripped := strip_tracking(u, context.temp_allocator); stripped do return clean
	return u
}

shield_level :: proc() -> Level {
	return settings().shieldLevel
}

Shields :: struct {
	filters:     [dynamic]^WebKitUserContentFilter,
	waiting:     [dynamic]^WebKitUserContentManager,
	store:       ^WebKitUserContentFilterStore,
	dir:         string,
	/// a load, build or compile is under way (one at a time)
	busy:        bool,
	/// lists being fetched
	fetching:    int,
	/// the level whose rules are in place
	have:        Maybe(Level),
	/// the lists changed since: the rules are made again
	stale:       bool,
	fetch_tried: [Level]bool,
	/// its rules could not be made (tried again when the lists change)
	failed:      [Level]bool,
	session:     ^SoupSession,
	/// a new set of rules is in place: pages already open take it
	installed:   proc(),
}

shields: Shields

shields_start :: proc() {
	shields.dir = join({cache_dir(), "shields"})
	make_dirs(join({shields.dir, "lists"}, context.temp_allocator))
	// here, before any thread can ask for it
	_ = builtin_hosts()
	when ENGINE_CEF {
		// the matcher the last start made, read now; or, the first time,
		// Iris's own domains: either way requests are checked from the start
		if !cef_load_cached(shield_level()) do cef_boot(shield_level())
	} else {
		shields.store = webkit_user_content_filter_store_new(cstr(shields.dir))
		forget_old_rules()
	}
	shields_settle()
	after(8000, proc(_: rawptr) { refresh_lists() }, nil)
}

/// a level asked for while rules are being made waits its turn: the rules
/// in place always end up the level the settings say
shields_level_changed :: proc() { shields_settle() }

/// whatever is in place catches up with the level asked for and the lists
/// on disk, one job at a time (each job ends with shields_done)
shields_settle :: proc() {
	if shields.busy || shields.fetching > 0 do return
	l := shield_level()
	if have, ok := shields.have.?; ok && have == l && !shields.stale do return
	if shields.failed[l] && !shields.stale do return
	if shields.stale {
		shields_build(l)
		return
	}
	when ENGINE_CEF {
		if cef_load_cached(l) do return
		shields_build(l)
	} else {
		shields_load(l)
	}
}

@(private="file") shields_done :: proc() {
	shields.busy = false
	shields_settle()
}

shields_ready :: proc() -> bool {
	return len(shields.filters) > 0
}

/// what the converter makes changes with this: rules made by an older
/// Iris are made again (and the old ones removed from WebKit's store)
RULES_REV :: 4

@(private="file") ids_path :: proc(l: Level, rev := RULES_REV) -> string {
	if rev < 2 do return fmt.tprintf("%s/%v.ids", shields.dir, l)
	return fmt.tprintf("%s/%v.r%d.ids", shields.dir, l, rev)
}

/// WebKit removes a compiled rule set only when it is given somewhere to
/// answer: with no callback it refuses ("assertion 'callback' failed") and
/// the old set stays on disk for good. Nothing waits for the answer.
@(private="file") removed :: proc "c" (o: ^GObject, res: ^GAsyncResult, d: rawptr) {}

/// the rules compiled before RULES_REV, and lists Iris no longer reads, go
@(private="file") forget_old_rules :: proc() {
	for l in Level do for rev in 1 ..< RULES_REV {
		p := ids_path(l, rev)
		text, ok := read_file(p, context.temp_allocator)
		if !ok do continue
		s := string(text)
		for id in strings.split_lines_iterator(&s) do if len(id) > 0 {
			webkit_user_content_filter_store_remove(shields.store, cstr(id), nil, rawptr(removed), nil)
		}
		os.remove(p)
	}
	for name in ([?]string{"ublock", "ublock-privacy", "quick-fixes", "unbreak"}) {
		os.remove(fmt.tprintf("%s/lists/%s.txt", shields.dir, name))
	}
}

@(private="file") list_file :: proc(l: List, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%s/lists/%s.txt", shields.dir, list_id(l), allocator = allocator)
}

// ---------------------------------------------------------------- CEF: the matcher's file

when ENGINE_CEF {

@(private="file") cef_cache_path :: proc(l: Level) -> string {
	return fmt.tprintf("%s/cef-%v.bin", shields.dir, l)
}

/// what the matcher of a level is made from: the converter, Iris's own
/// list, and each list's file as it is now
@(private="file") cef_cache_key :: proc(l: Level, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, "r%d %v %08x", RULES_REV, l, builtin_rev())
	for li in level_lists(l) {
		fi, err := os.stat(list_file(li), context.temp_allocator)
		if err != nil {
			fmt.sbprintf(&b, " %s:-", list_id(li))
		} else {
			fmt.sbprintf(&b, " %s:%d:%d", list_id(li), fi.size, time.to_unix_nanoseconds(fi.modification_time))
		}
	}
	return strings.to_string(b)
}

/// the matcher the last build of this level left, when the lists are still
/// those it was made from
@(private="file") cef_load_cached :: proc(l: Level) -> bool {
	start := time.now()
	data, ok := read_file(cef_cache_path(l), runtime.heap_allocator())
	if !ok do return false
	m := matcher_load(data, cef_cache_key(l))
	if m == nil do return false
	cef_shields_install(m)
	shields.have = l
	log.debugf("shields: the %v matcher read in %.0f ms", l, time.duration_milliseconds(time.since(start)))
	return true
}

/// the first start: Iris's own domains (and what is always left alone)
/// until the lists come
@(private="file") cef_boot :: proc(l: Level) {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	c := Converter{level = l, builtin = true}
	r := converter_rules(&c)
	if m := matcher_from(&r); m != nil do cef_shields_install(m)
}

}

// ---------------------------------------------------------------- loading what was compiled before (WPE)

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
	ids := ok ? strings.split_lines(strings.trim_space(string(text)), context.temp_allocator) : nil
	if len(ids) == 0 || ids[0] == "" {
		shields_build(l)
		return
	}
	shields.busy = true
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
	i := one.i
	free(one)
	err: ^GError
	f := webkit_user_content_filter_store_load_finish(cast(^WebKitUserContentFilterStore)o, res, &err)
	if err != nil do g_error_free(err)
	job.got[i] = f
	if f == nil do job.failed = true
	job.left -= 1
	if job.left > 0 do return
	defer {
		delete(job.got)
		free(job)
	}
	if job.failed {
		for g in job.got do if g != nil do webkit_user_content_filter_unref(g)
		shields.busy = false
		shields_build(job.l)
	} else {
		shields_install(job.got, job.l)
		shields_done()
	}
}

// ---------------------------------------------------------------- building: lists -> rules, on a thread

@(private="file") Build :: struct {
	l:       Level,
	paths:   [dynamic]string,
	lists:   [dynamic]List,
	key:     string,
	parts:   []string, // (WPE, from the heap)
	matcher: ^Matcher, // (CEF)
}

@(private="file") shields_build :: proc(l: Level) {
	missing: [dynamic]List
	defer delete(missing)
	for li in level_lists(l) do if !os.exists(list_file(li)) do append(&missing, li)
	if len(missing) > 0 && !shields.fetch_tried[l] {
		shields.fetch_tried[l] = true
		fetch(missing[:], l, false)
		// rules already in place (CEF always has some) wait for the lists;
		// with none, Iris's own domains are made into rules meanwhile
		_, have := shields.have.?
		if ENGINE_CEF || have do return
	}
	shields.busy = true
	shields.stale = false
	job := new(Build)
	job.l = l
	for li in level_lists(l) {
		append(&job.paths, list_file(li, context.allocator))
		append(&job.lists, li)
	}
	when ENGINE_CEF do job.key = cef_cache_key(l, context.allocator)
	thread.create_and_start_with_poly_data(job, proc(job: ^Build) {
		start := time.now()
		arena: virtual.Arena
		_ = virtual.arena_init_growing(&arena)
		{
			context.allocator = virtual.arena_allocator(&arena)
			conv := Converter{level = job.l}
			any := false
			for p, i in job.paths {
				t := read_file(p) or_continue
				converter_add_list(&conv, string(t), list_generic_ok(job.lists[i]), list_ultra_only(job.lists[i]))
				any = true
			}
			// Iris's own domains: until the lists come, and at the ultra
			// level with them
			conv.builtin = !any || job.l == .ultra
			rules := converter_rules(&conv)
			when ENGINE_CEF {
				data := matcher_bytes(&rules, job.key)
				context.allocator = main_context.allocator
				virtual.arena_destroy(&arena)
				write_file(cef_cache_path(job.l), data)
				job.matcher = matcher_load(data, job.key)
			} else {
				max_rules := 120_000
				if v, ok := strconv.parse_int(os.get_env("IRIS_SHIELDS_PART", context.temp_allocator)); ok do max_rules = v
				job.parts = rules_json(&rules, max_rules, runtime.heap_allocator())
				context.allocator = main_context.allocator
				virtual.arena_destroy(&arena)
			}
		}
		log.debugf("shields: the %v rules made in %.0f ms", job.l, time.duration_milliseconds(time.since(start)))
		// this thread's temporary memory (its own: init_context leaves it to us)
		runtime.default_temp_allocator_destroy(&runtime.global_default_temp_allocator_data)
		idle(proc(d: rawptr) {
			job := cast(^Build)d
			defer {
				for p in job.paths do delete(p)
				delete(job.paths)
				delete(job.lists)
				delete(job.key)
				free(job)
			}
			when ENGINE_CEF {
				if job.matcher == nil {
					shields.failed[job.l] = true
				} else if job.l != shield_level() {
					matcher_free(job.matcher)
				} else {
					cef_shields_install(job.matcher)
					shields.have = job.l
				}
				shields_done()
			} else {
				// WebKit copies the JSON: it goes as soon as it is handed over
				shields_compile(job.parts, job.l)
				for p in job.parts do delete(p, runtime.heap_allocator())
				delete(job.parts, runtime.heap_allocator())
			}
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
	if len(parts) == 0 {
		shields.failed[l] = true
		shields_done()
		return
	}
	shields.busy = true
	job := new(Compile)
	stamp := time.to_unix_seconds(time.now())
	job^ = {l = l, ids = make([]string, len(parts)), got = make([]^WebKitUserContentFilter, len(parts)), left = len(parts)}
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
	defer {
		for id in job.ids do delete(id)
		delete(job.ids)
		delete(job.got)
		free(job)
		shields_done()
	}
	for g in job.got do if g == nil {
		for x in job.got do if x != nil do webkit_user_content_filter_unref(x)
		shields.failed[job.l] = true
		return
	}
	// the parts compiled before go
	if old, ok := read_file(ids_path(job.l), context.temp_allocator); ok {
		s := string(old)
		outer: for id in strings.split_lines_iterator(&s) {
			for n in job.ids do if n == id do continue outer
			webkit_user_content_filter_store_remove(shields.store, cstr(id), nil, rawptr(removed), nil)
		}
	}
	write_file(ids_path(job.l), transmute([]u8)strings.join(job.ids, "\n", context.temp_allocator))
	shields_install(job.got, job.l)
}

@(private="file") shields_install :: proc(made: []^WebKitUserContentFilter, l: Level) {
	// a level changed meanwhile: shields_done makes that one next
	if l != shield_level() {
		for m in made do if m != nil do webkit_user_content_filter_unref(m)
		return
	}
	for f in shields.filters do webkit_user_content_filter_unref(f)
	clear(&shields.filters)
	for m in made do if m != nil do append(&shields.filters, m)
	for ucm in shields.waiting do for f in shields.filters do webkit_user_content_manager_add_filter(ucm, f)
	clear(&shields.waiting)
	shields.have = l
	if shields.installed != nil do shields.installed()
}

// ---------------------------------------------------------------- the lists, from uBlock's mirrors

@(private="file") refresh_lists :: proc() {
	// rules given (IRIS_SHIELDS_JSON, the tests): no lists
	if len(env("IRIS_SHIELDS_JSON")) > 0 do return
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
	wrote:       bool,
}

@(private="file") Get :: struct {
	fetch:  ^Fetch,
	list:   List,
	mirror: int,
	msg:    ^SoupMessage,
}

@(private="file") fetch :: proc(lists: []List, l: Level, rebuild_all: bool) {
	if shields.session == nil do shields.session = soup_session_new()
	shields.fetching += 1
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
	if len(data) > 1000 && (data[0] == '!' || data[0] == '[') && write_file(list_file(g.list), data) do f.wrote = true
	free(g)
	f.left -= 1
	if f.left > 0 do return
	defer free(f)
	shields.fetching -= 1
	if f.wrote {
		// every level is made again from the new lists (the one in use
		// now; the others when they are next asked for)
		shields.stale = true
		shields.failed = {}
		when !ENGINE_CEF {
			if f.rebuild_all do for other in Level do if other != shield_level() do os.remove(ids_path(other))
		}
	}
	shields_settle()
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
	set := builtin_hosts()
	testing.expect(t, strings.count(set, "\n") > 150_000)
	// sorted as set_has needs it (byte order), lower case, one name a line
	prev := ""
	s := set
	sorted := true
	for line in strings.split_lines_iterator(&s) {
		if line <= prev || len(line) == 0 do sorted = false
		prev = line
	}
	testing.expect(t, sorted)
	testing.expect(t, !host_blocked("example.com"))
	testing.expect(t, host_blocked("doubleclick.net"))
	testing.expect(t, host_blocked("stats.g.doubleclick.net"))
	// consent managers are in the list, and never blocked
	testing.expect(t, !host_blocked("cdn.cookielaw.org"))
	testing.expect(t, !host_blocked("geolocation.onetrust.com"))
}

/// a link you click, in a webmail above all, goes through an email
/// click-tracker that Iris's list blocks: it opens all the same (a reset
/// password link must work); a page's own pop-up to one does not
@(test) test_links_through_trackers :: proc(t: ^testing.T) {
	page := "https://mail.example.com/inbox"
	for u in ([?]string{"https://abc.r.us-east-1.awstrack.me/L0/https:%2F%2Fexample.com", "https://klclick.com/ls/click?x=1", "https://d1.hubspotlinks.com/Ctc/x", "https://r20.rs6.net/tn.jsp?f=1"}) {
		h, _ := host_of(u, context.temp_allocator)
		testing.expectf(t, host_blocked(h), "%s is in Iris's list", h)
		testing.expect_value(t, new_window_choice(u, page, true, true, false, true), Window_Choice.Own_Tab)
		testing.expect_value(t, new_window_choice(u, page, false, true, false, true), Window_Choice.Block)
	}
}
