// Iris for Linux: Odin, Wayland, EGL/GLES and WPE WebKit. No GTK, no X11.
//
// One loop runs everything: GLib's (WebKit needs it). The compositor's
// socket and the key-repeat timer are two of its sources, and just before
// GLib sleeps, Iris reads what the compositor already sent and sends what
// it has written (its poll function wraps GLib's).
package iris

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import cef "cef"
import plat "../plat"
import wl "../wl"

foreign import glib "system:glib-2.0"

main_context: runtime.Context
main_loop: ^GMainLoop

GPollFD :: struct {
	fd:      i32,
	events:  u16,
	revents: u16,
}
GPollFunc :: proc "c" (fds: [^]GPollFD, n: u32, timeout: i32) -> i32

@(default_calling_convention = "c")
foreign glib {
	g_main_context_default :: proc() -> ^GMainContext ---
	g_main_context_set_poll_func :: proc(ctx: ^GMainContext, f: GPollFunc) ---
	g_poll :: proc(fds: [^]GPollFD, n: u32, timeout: i32) -> i32 ---
}

/// GLib is about to wait: what the compositor sent is handled, and what
/// Iris wrote goes out
@(private="file") poll_with_wayland :: proc "c" (fds: [^]GPollFD, n: u32, timeout: i32) -> i32 {
	context = main_context
	// a turn of the loop is over: what it made for the moment goes
	free_all(context.temp_allocator)
	w := &b.win
	if w.display != nil {
		for wl.display_prepare_read(w.display) != 0 {
			if wl.display_dispatch_pending(w.display) < 0 do break
		}
		wl.display_cancel_read(w.display)
		wl.display_flush(w.display)
	}
	return g_poll(fds, n, timeout)
}

USAGE :: `Iris %s: a browser made of glass.

  iris [ADDRESS...]                open Iris (with these pages)
  iris --engine=cef [ADDRESS...]   open Iris with the CEF page engine
                                   (WPE is the default; CEF is the
                                   experiment beside it, slice 2)
  iris --engine=cef --cef-check    headless: load one page with CEF and
                                   check its title, one JS eval and one
                                   frame (for CI)
  iris --shield-rules LEVEL DIR OUT
                                   the content rules a Shields level makes from
                                   the lists in DIR, written to OUT (for checks)
  iris --version
`

main :: proc() {
	main_context = context
	args := os.args[1:]
	// --engine=cef picks the CEF page engine; WPE is the default.
	// The flag is scanned from all arguments (it may come after a
	// URL), and an unknown engine is a usage error.
	cef_check := false
	for a in args {
		if strings.has_prefix(a, "--engine=") {
			switch a[len("--engine="):] {
			case "cef":
				engine_kind = .CEF
			case "wpe":
				engine_kind = .WPE
			case:
				fmt.eprintf("iris: unknown engine %q (wpe or cef)\n", a[len("--engine="):])
				os.exit(2)
			}
		}
		if a == "--cef-check" do cef_check = true
	}
	if len(args) > 0 {
		switch args[0] {
		case "--version", "-v":
			fmt.println("Iris", VERSION)
			return
		case "--help", "-h":
			fmt.printf(USAGE, VERSION)
			return
		case "--render-check":
			os.exit(render_check(len(args) > 1 ? args[1] : "iris-render.ppm"))
		case "--shield-rules":
			if len(args) != 4 {
				fmt.eprintf(USAGE, VERSION)
				os.exit(2)
			}
			os.exit(shield_rules_cli(args[1], args[2], args[3]))
		}
	}
	// CEF's subprocesses re-enter main here: this call must come
	// before anything that opens a window, and it must run in both
	// modes — only cef_execute_process can tell a subprocess from
	// the browser process (a subprocess's argv carries no --engine
	// flag of its own). A subprocess exits with the code CEF gives.
	cef_args := cef_browser_args()
	if code, is_sub := cef.startup(cef_args); is_sub {
		os.exit(code)
	}
	if engine_kind == .CEF {
		// The cache lives under the browser's cache dir, beside
		// WPE's. Resources and locales default to next to libcef.so.
		if !cef.init(cef.Init_Options{cache_dir = join({cache_dir(), "cef"})}) {
			fmt.eprintln("Iris: CEF failed to start (missing ICU data next to libcef.so?)")
			os.exit(1)
		}
		// The external message pump: CEF's work runs on a timer,
		// on this thread, like everything else in the browser.
		every(16, proc(_: rawptr) -> bool {
			cef.pump()
			return true
		}, nil)
	}
	if cef_check {
		if engine_kind != .CEF {
			fmt.eprintln("iris: --cef-check needs --engine=cef")
			os.exit(2)
		}
		code := cef_check_run()
		cef.shutdown()
		os.exit(code)
	}
	video_environment()
	// WebKit names its sandboxed web processes after this (WTF::applicationID),
	// and the Flatpak portal only lets them start under the app's own ID:
	// "iris" is not a valid ID, so WebKit made one up and the portal refused it.
	g_set_prgname(APP_ID)
	g_set_application_name("Iris")
	main_loop = g_main_loop_new(nil, 0)
	g_main_context_set_poll_func(g_main_context_default(), poll_with_wayland)

	containers_ensure()
	session_made = downloads_listen
	shields.installed = browser_reapply_shields
	shields_start()

	if !browser_start() {
		fmt.eprintln("Iris needs a Wayland session (WAYLAND_DISPLAY), with EGL and OpenGL ES 3.")
		os.exit(1)
	}
	w := &b.win
	display_fd, repeat_fd := plat.fds(w)
	g_unix_fd_add_full(G_PRIORITY_DEFAULT, i32(display_fd), G_IO_IN | G_IO_HUP | G_IO_ERR, proc "c" (fd: i32, cond: u32, d: rawptr) -> gboolean {
		context = main_context
		if !plat.pump(&b.win) || b.win.closed {
			g_main_loop_quit(main_loop)
			return 0
		}
		return 1
	}, nil, nil)
	if repeat_fd >= 0 {
		g_unix_fd_add_full(G_PRIORITY_DEFAULT, i32(repeat_fd), G_IO_IN, proc "c" (fd: i32, cond: u32, d: rawptr) -> gboolean {
			context = main_context
			plat.repeat_fired(&b.win)
			return 1
		}, nil, nil)
	}

	browser_restore()
	cwd, _ := os.get_working_directory(context.temp_allocator)
	for a in args {
		if strings.has_prefix(a, "-") do continue
		u := resolve_arg(a, cwd, context.temp_allocator)
		if len(u) > 0 do browser_new_tab({url = u, select = true})
	}
	if len(b.tabs) == 0 do browser_new_tab({select = true})
	after(3000, proc(_: rawptr) { updates_check() }, nil)

	g_main_loop_run(main_loop)
	browser_save_session()
	history_flush()
	plat.close_window(w)
	if engine_kind == .CEF {
		// The process is exiting; the smoke test proves shutdown
		// with live browsers exits cleanly.
		cef.shutdown()
	}
}

// cef_browser_args is the argv CEF's subprocess check sees: the real
// argv, plus the headless flags when there is no display (CI, or a
// machine without a compositor) and the certificate override only
// when the environment explicitly asks for it (the egress proxy
// MITMs TLS; a real user never sets this).
@(private="file") cef_browser_args :: proc() -> []string {
	if engine_kind != .CEF do return os.args
	args := make([dynamic]string, 0, len(os.args) + 8)
	append(&args, ..os.args)
	if os.get_env("DISPLAY", context.temp_allocator) == "" {
		append(&args, "--headless=new", "--ozone-platform=headless", "--use-gl=angle", "--use-angle=swiftshader", "--enable-unsafe-swiftshader")
	}
	if os.get_env("IRIS_CEF_IGNORE_CERT_ERRORS", context.temp_allocator) == "1" {
		append(&args, "--ignore-certificate-errors")
	}
	return args[:]
}

G_IO_HUP :: u32(16)
G_IO_ERR :: u32(8)
