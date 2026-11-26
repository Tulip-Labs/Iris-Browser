// Iris Shields: ad and tracker blocking inside the engine. uBlock Origin's
// and EasyList's lists (fetched every four days from uBlock's mirrors) are
// turned into rules on a thread (rules.odin), kept in a compact file of
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
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

// the Flatpak's ID: the window's app_id
APP_ID :: "io.github.tulip_labs.Iris.Cef"
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
	// the matcher the last start made, read now; or, the first time,
	// Iris's own domains: either way requests are checked from the start
	if !cef_load_cached(shield_level()) do cef_boot(shield_level())
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
	if cef_load_cached(l) do return
	shields_build(l)
}

@(private="file") shields_done :: proc() {
	shields.busy = false
	shields_settle()
}

/// what the converter makes changes with this: the matcher made by an older
/// Iris is made again
RULES_REV :: 4

@(private="file") list_file :: proc(l: List, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%s/lists/%s.txt", shields.dir, list_id(l), allocator = allocator)
}

// ---------------------------------------------------------------- the matcher's file

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
	cef_adblock_install(adblock_cache_load(l, adblock_key(cef_cache_key(l))))
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

// ---------------------------------------------------------------- building: lists -> rules, on a thread

@(private="file") Build :: struct {
	l:       Level,
	paths:   [dynamic]string,
	lists:   [dynamic]List,
	key:     string,
	matcher: ^Matcher,
	adblock: ^Adblock, // Brave's engine, from the same lists (cef_adblock.odin)
}

@(private="file") shields_build :: proc(l: Level) {
	missing: [dynamic]List
	defer delete(missing)
	for li in level_lists(l) do if !os.exists(list_file(li)) do append(&missing, li)
	if len(missing) > 0 && !shields.fetch_tried[l] {
		shields.fetch_tried[l] = true
		fetch(missing[:], l, false)
		// the rules in place (there are always some) wait for the lists
		return
	}
	shields.busy = true
	shields.stale = false
	job := new(Build)
	job.l = l
	for li in level_lists(l) {
		append(&job.paths, list_file(li, context.allocator))
		append(&job.lists, li)
	}
	job.key = cef_cache_key(l, context.allocator)
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
			data := matcher_bytes(&rules, job.key)
			context.allocator = main_context.allocator
			virtual.arena_destroy(&arena)
			write_file(cef_cache_path(job.l), data)
			job.matcher = matcher_load(data, job.key)
			// Brave's engine from the same lists, for the cosmetic
			// filters, scriptlets, redirects and $removeparam the matcher
			// has no form for
			job.adblock = adblock_build(job.paths[:])
			adblock_cache_save(job.adblock, job.l, adblock_key(job.key))
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
			if job.matcher == nil {
				shields.failed[job.l] = true
				if job.adblock != nil do iris_adblock_destroy(job.adblock)
			} else if job.l != shield_level() {
				matcher_free(job.matcher)
				if job.adblock != nil do iris_adblock_destroy(job.adblock)
			} else {
				// the engine first: the matcher's install reapplies the shield to every page
				cef_adblock_install(job.adblock)
				cef_shields_install(job.matcher)
				shields.have = job.l
			}
			shields_done()
		}, job)
	}, init_context = main_context, self_cleanup = true)
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
	adblock_resources_refresh()
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
	}
	shields_settle()
}

// ---------------------------------------------------------------- pages

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
