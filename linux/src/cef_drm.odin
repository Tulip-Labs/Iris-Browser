// DRM (Widevine) for the CEF engine. Google's licence does not let a
// browser of ours ship the Widevine CDM, so Iris never carries one: it finds
// the one a browser already on this machine has (Chrome, Chromium, Brave,
// Firefox), copies it into its own data folder, and tells Chromium where it
// is the way Chromium's own component updater does on Linux (the "hint
// file" in the profile's WidevineCdm folder). Nothing is fetched.
//
// Chromium reads the hint file when it starts, so a CDM found now plays
// from the next start. IRIS_WIDEVINE_DIR names a CDM folder by hand (one
// with manifest.json, or a folder of such version folders).
package iris

import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"


WIDEVINE_LIB :: "libwidevinecdm.so"
WIDEVINE_HINT :: "latest-component-updated-widevine-cdm"

/// a CDM found on this machine
Widevine_Found :: struct {
	dir:     string, // folder with manifest.json
	lib:     string, // the library
	version: string,
}

/// where an installed browser keeps its CDM (a version folder, or a folder of them)
@(private="file") widevine_roots :: proc() -> []string {
	h := home_dir()
	out := make([dynamic]string, context.temp_allocator)
	if d := env("IRIS_WIDEVINE_DIR"); len(d) > 0 do append(&out, d)
	rel := [?]string{
		".config/google-chrome/WidevineCdm", ".config/google-chrome-beta/WidevineCdm", ".config/google-chrome-unstable/WidevineCdm",
		".config/chromium/WidevineCdm", ".config/BraveSoftware/Brave-Browser/WidevineCdm",
		".config/microsoft-edge/WidevineCdm", ".config/vivaldi/WidevineCdm", ".config/opera/WidevineCdm",
		".var/app/com.google.Chrome/config/google-chrome/WidevineCdm",
		".var/app/org.chromium.Chromium/config/chromium/WidevineCdm",
		".var/app/com.brave.Browser/config/BraveSoftware/Brave-Browser/WidevineCdm",
	}
	for r in rel do append(&out, join({h, r}, context.temp_allocator))
	abs_dirs := [?]string{
		"/opt/google/chrome/WidevineCdm", "/opt/brave.com/brave/WidevineCdm", "/opt/microsoft/msedge/WidevineCdm",
		"/usr/lib/chromium/WidevineCdm", "/usr/lib64/chromium-browser/WidevineCdm", "/usr/lib/chromium-browser/WidevineCdm",
		"/usr/lib/brave-bin/WidevineCdm",
	}
	for r in abs_dirs do append(&out, strings.clone(r, context.temp_allocator))
	// Firefox keeps the same library, one folder per version, in each profile
	for ff in ([?]string{".mozilla/firefox", ".var/app/org.mozilla.firefox/.mozilla/firefox"}) {
		base := join({h, ff}, context.temp_allocator)
		for p in subdirs(base) do append(&out, join({base, p, "gmp-widevinecdm"}, context.temp_allocator))
	}
	return out[:]
}

/// the names of the folders in a folder (none if it is not there)
@(private="file") subdirs :: proc(path: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	d, err := os.open(path)
	if err != nil do return out[:]
	defer os.close(d)
	fis, _ := os.read_dir(d, -1, context.temp_allocator)
	for fi in fis do if fi.type == .Directory do append(&out, strings.clone(fi.name, context.temp_allocator))
	return out[:]
}

/// the "version" of a CDM's manifest.json ("" when it has none)
widevine_manifest_version :: proc(manifest: string) -> string {
	i := strings.index(manifest, "\"version\"")
	if i < 0 do return ""
	rest := manifest[i + len("\"version\""):]
	q1 := strings.index_byte(rest, '"')
	if q1 < 0 do return ""
	rest = rest[q1 + 1:]
	q2 := strings.index_byte(rest, '"')
	if q2 < 0 do return ""
	v := rest[:q2]
	// only digits and dots: it becomes a folder name
	if len(v) == 0 || len(v) > 32 do return ""
	for c in v do if !(c >= '0' && c <= '9') && c != '.' do return ""
	return v
}

/// is a newer than b? (dotted numbers)
widevine_newer :: proc(a, b: string) -> bool {
	as := strings.split(a, ".", context.temp_allocator)
	bs := strings.split(b, ".", context.temp_allocator)
	for i in 0 ..< max(len(as), len(bs)) {
		x, y := 0, 0
		if i < len(as) do x, _ = strconv.parse_int(as[i])
		if i < len(bs) do y, _ = strconv.parse_int(bs[i])
		if x != y do return x > y
	}
	return false
}

/// a version folder's CDM, if it has a manifest and the library
@(private="file") widevine_at :: proc(dir: string) -> (f: Widevine_Found, ok: bool) {
	m, rok := read_file(join({dir, "manifest.json"}, context.temp_allocator), context.temp_allocator)
	if !rok do return
	v := widevine_manifest_version(string(m))
	if len(v) == 0 do return
	lib := join({dir, "_platform_specific", "linux_x64", WIDEVINE_LIB}, context.temp_allocator)
	if !os.exists(lib) do lib = join({dir, WIDEVINE_LIB}, context.temp_allocator) // Firefox's layout
	if !os.exists(lib) do return
	return {dir, lib, v}, true
}

/// the newest CDM any installed browser has
widevine_find :: proc() -> (best: Widevine_Found, ok: bool) {
	for root in widevine_roots() {
		if f, k := widevine_at(root); k {
			if !ok || widevine_newer(f.version, best.version) do best, ok = f, true
			continue
		}
		for v in subdirs(root) {
			if f, k := widevine_at(join({root, v}, context.temp_allocator)); k {
				if !ok || widevine_newer(f.version, best.version) do best, ok = f, true
			}
		}
	}
	return
}

/// the CDM Iris keeps for Chromium: <profile root>/WidevineCdm/<version>/
@(private="file") staged_dir :: proc(root, version: string) -> string {
	return join({root, "WidevineCdm", version}, context.temp_allocator)
}

/// copies a CDM into the profile root and points Chromium's hint file at it
/// (nothing is rewritten when the same version is there). Runs before CEF
/// starts. Returns the version now staged ("" if there is none).
widevine_stage :: proc(root: string) -> string {
	f, ok := widevine_find()
	if !ok {
		// one staged earlier stays in use
		hint, hok := read_file(join({root, "WidevineCdm", WIDEVINE_HINT}, context.temp_allocator), context.temp_allocator)
		if hok && strings.contains(string(hint), "\"Path\"") do return "kept"
		return ""
	}
	dst := staged_dir(root, f.version)
	dst_lib := join({dst, "_platform_specific", "linux_x64", WIDEVINE_LIB}, context.temp_allocator)
	if !os.exists(dst_lib) {
		lib, lok := read_file(f.lib, context.temp_allocator)
		man, mok := read_file(join({f.dir, "manifest.json"}, context.temp_allocator), context.temp_allocator)
		if !lok || !mok || len(lib) < 1 << 16 {
			log.warnf("Widevine: could not read the CDM in %s", f.dir)
			return ""
		}
		if !write_file(dst_lib, lib) || !write_file(join({dst, "manifest.json"}, context.temp_allocator), man) {
			log.warn("Widevine: could not copy the CDM into Iris's folder")
			return ""
		}
	}
	// {"Path": "<version folder>"}: what Chromium's component updater writes
	hint := fmt.tprintf("{{\"Path\":\"%s\"}}", dst)
	cur, cok := read_file(join({root, "WidevineCdm", WIDEVINE_HINT}, context.temp_allocator), context.temp_allocator)
	if !cok || string(cur) != hint {
		write_file(join({root, "WidevineCdm", WIDEVINE_HINT}, context.temp_allocator), transmute([]u8)hint)
	}
	return strings.clone(f.version, context.temp_allocator)
}

/// what DRM is, for the log and the About page
widevine_status :: proc(root: string) -> string {
	if _, ok := read_file(join({root, "WidevineCdm", WIDEVINE_HINT}, context.temp_allocator), context.temp_allocator); ok {
		return "Widevine: on"
	}
	return "Widevine: no CDM found (install Chrome, Chromium or Brave once, or set IRIS_WIDEVINE_DIR)"
}


@(test) test_widevine_manifest :: proc(t: ^testing.T) {
	v := widevine_manifest_version(`{"manifest_version": 2, "name": "WidevineCdm", "version": "4.10.2891.0"}`)
	testing.expect_value(t, v, "4.10.2891.0")
	testing.expect_value(t, widevine_manifest_version(`{"version": "../../x"}`), "")
	testing.expect_value(t, widevine_manifest_version(`{}`), "")
	testing.expect(t, widevine_newer("4.10.2891.0", "4.10.2710.0"))
	testing.expect(t, !widevine_newer("4.10.2710.0", "4.10.2710.0"))
	testing.expect(t, widevine_newer("4.10.10.0", "4.10.9.0"))
}


@(test) test_widevine_stage :: proc(t: ^testing.T) {
	base := fmt.tprintf("/tmp/iris-wv-test-%d", os.get_pid())
	src := join({base, "cdm", "4.10.1.0"}, context.temp_allocator)
	root := join({base, "root"}, context.temp_allocator)
	defer os.remove_all(base)
	lib := make([]u8, 1 << 17, context.temp_allocator)
	write_file(join({src, "manifest.json"}, context.temp_allocator), transmute([]u8)string(`{"name":"WidevineCdm","version":"4.10.1.0"}`))
	write_file(join({src, "_platform_specific", "linux_x64", WIDEVINE_LIB}, context.temp_allocator), lib)
	os.set_env("IRIS_WIDEVINE_DIR", join({base, "cdm"}, context.temp_allocator))
	defer os.unset_env("IRIS_WIDEVINE_DIR")
	testing.expect_value(t, widevine_stage(root), "4.10.1.0")
	hint, ok := read_file(join({root, "WidevineCdm", WIDEVINE_HINT}, context.temp_allocator), context.temp_allocator)
	testing.expect(t, ok)
	testing.expect(t, strings.contains(string(hint), "WidevineCdm/4.10.1.0"))
	testing.expect(t, os.exists(join({root, "WidevineCdm", "4.10.1.0", "_platform_specific", "linux_x64", WIDEVINE_LIB}, context.temp_allocator)))
	// a second call changes nothing and still answers
	testing.expect_value(t, widevine_stage(root), "4.10.1.0")
}

