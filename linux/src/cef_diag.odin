// What Iris tells when something goes wrong or slow, for a machine nobody can
// look at:
// - <data>/crash.log: every way Iris ends, with the reason (a signal and its
//   backtrace, exit(), the window closing, the engine failing to start), and
//   the steps of the GPU ladder; read it after "it closed by itself"
// - IRIS_PERF=1 (or iris --perf): every 5 s on stderr, the frames per second
//   (GPU or CPU frames), Iris's own CPU use, and Chromium's processes with
//   theirs, to see which one is eating the CPU
package iris

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"
import "core:time"

foreign import diag_libc "system:c"

@(default_calling_convention = "c")
foreign diag_libc {
	backtrace :: proc(buf: [^]rawptr, size: i32) -> i32 ---
	backtrace_symbols_fd :: proc(buf: [^]rawptr, size: i32, fd: i32) ---
	atexit :: proc(f: proc "c" ()) -> i32 ---
	write :: proc(fd: i32, buf: rawptr, n: uint) -> int ---
}

/// frames shown since start: from Chromium's GPU (DMA-BUF), and CPU (OnPaint)
cef_frames_gpu, cef_frames_cpu: u64

@(private = "file") crash_fd: i32 = -1
@(private = "file") exit_noted: bool

/// a line in crash.log (and on stderr when it says why Iris ends)
cef_diag_log :: proc(format: string, args: ..any) {
	line := fmt.tprintf(format, ..args)
	diag_write(fmt.tprintf("%s iris[%d] %s\n", stamp(), linux.getpid(), line))
}

@(private = "file") stamp :: proc() -> string {
	t := time.now()
	y, mo, d := time.date(t)
	h, mi, s := time.clock(t)
	return fmt.tprintf("%04d-%02d-%02d %02d:%02d:%02d", y, int(mo), d, h, mi, s)
}

@(private = "file") diag_write :: proc(s: string) {
	if crash_fd >= 0 do write(crash_fd, raw_data(s), uint(len(s)))
}

/// why Iris ends, said once: the log, and stderr
cef_diag_exit :: proc(reason: string) {
	if intrinsics.atomic_exchange(&exit_noted, true) do return
	cef_diag_log("exit: %s", reason)
}

@(private = "file") fatal_signal :: proc "c" (sig: posix.Signal) {
	context = runtime.default_context()
	msg := fmt.tprintf("fatal signal %d (%v): backtrace follows\n", int(sig), sig)
	diag_write(msg)
	write(2, raw_data(msg), uint(len(msg)))
	frames: [64]rawptr
	n := backtrace(&frames[0], 64)
	if crash_fd >= 0 do backtrace_symbols_fd(&frames[0], n, crash_fd)
	backtrace_symbols_fd(&frames[0], n, 2)
	// the default action: the core dump and the exit status stay what they were
	dfl := posix.sigaction_t{}
	dfl.sa_handler = auto_cast posix.SIG_DFL
	posix.sigaction(sig, &dfl, nil)
	posix.raise(sig)
}

@(private = "file") polite_signal :: proc "c" (sig: posix.Signal) {
	context = runtime.default_context()
	diag_write(fmt.tprintf("%s iris[%d] signal %d (%v): Iris is asked to end\n", stamp(), linux.getpid(), int(sig), sig))
	dfl := posix.sigaction_t{}
	dfl.sa_handler = auto_cast posix.SIG_DFL
	posix.sigaction(sig, &dfl, nil)
	posix.raise(sig)
}

/// first thing after CEF started (it installs its own signal handlers; these
/// come after and end the same way): crash.log opens, the signals and every
/// exit are noted
cef_diag_start :: proc() {
	dir := data_dir()
	make_dirs(dir)
	path := fmt.ctprintf("%s/crash.log", dir)
	// a log that grows without end is no help: past 256 KB it starts again
	if fi, err := os.stat(string(path), context.temp_allocator); err == nil && fi.size > 256 << 10 {
		os.rename(string(path), fmt.tprintf("%s/crash.log.1", dir))
	}
	fd, err := linux.open(path, {.WRONLY, .CREAT, .APPEND, .CLOEXEC}, {.IRUSR, .IWUSR})
	if err == .NONE do crash_fd = i32(fd)
	cef_diag_log("start: Iris %s, %s", BUILD_VERSION, cef_gpu_level_text())
	for sig in ([?]posix.Signal{.SIGSEGV, .SIGABRT, .SIGBUS, .SIGFPE, .SIGILL}) {
		act := posix.sigaction_t{}
		act.sa_handler = fatal_signal
		act.sa_flags = {.RESETHAND}
		posix.sigaction(sig, &act, nil)
	}
	for sig in ([?]posix.Signal{.SIGTERM, .SIGHUP, .SIGINT}) {
		act := posix.sigaction_t{}
		act.sa_handler = polite_signal
		posix.sigaction(sig, &act, nil)
	}
	// a write to a socket whose other end is gone (the Wayland compositor,
	// a helper) must be an error to handle, not the end of Iris
	{
		act := posix.sigaction_t{}
		act.sa_handler = auto_cast posix.SIG_IGN
		posix.sigaction(.SIGPIPE, &act, nil)
	}
	atexit(proc "c" () {
		context = runtime.default_context()
		if !intrinsics.atomic_exchange(&exit_noted, true) {
			diag_write(fmt.tprintf("%s iris[%d] exit(): the process ends (no reason was given: exit() from a library, or main returning)\n", stamp(), linux.getpid()))
		} else {
			diag_write(fmt.tprintf("%s iris[%d] exit(): done\n", stamp(), linux.getpid()))
		}
	})
}

@(private = "file") cef_gpu_level_text :: proc() -> string {
	return fmt.tprintf("GPU step %d", cef_gpu_level)
}

// ---------------------------------------------------------------- IRIS_PERF

@(private = "file") Perf :: struct {
	at:       time.Time,
	gpu, cpu: u64,
	ticks:    u64,
}
@(private = "file") perf: Perf

perf_wanted :: proc() -> bool {
	if env("IRIS_PERF") == "1" do return true
	for a in os.args do if a == "--perf" do return true
	return false
}

/// the CPU time (clock ticks) a process has used, from its /proc/<pid>/stat
@(private = "file") cpu_ticks :: proc(stat: string) -> u64 {
	i := strings.last_index_byte(stat, ')')
	if i < 0 do return 0
	f := strings.fields(stat[i + 1:], context.temp_allocator)
	if len(f) < 13 do return 0
	u, _ := strconv.parse_u64(f[11])
	s, _ := strconv.parse_u64(f[12])
	return u + s
}

cef_perf_start :: proc() {
	if !perf_wanted() do return
	perf.at = time.now()
	perf.ticks = self_ticks()
	fmt.eprintfln("iris: IRIS_PERF on: a line every 5 s (frames/s, GPU or CPU path, Iris's CPU, Chromium's processes)")
	every(5000, proc(_: rawptr) -> bool {
		perf_report()
		return true
	}, nil)
}

@(private = "file") self_ticks :: proc() -> u64 {
	s, err := os.read_entire_file("/proc/self/stat", context.temp_allocator)
	if err != nil do return 0
	return cpu_ticks(string(s))
}

@(private = "file") perf_report :: proc() {
	now := time.now()
	dt := time.duration_seconds(time.diff(perf.at, now))
	if dt <= 0 do return
	CLK :: 100.0 // clock ticks per second on Linux
	ticks := self_ticks()
	gpu, cpu := intrinsics.atomic_load(&cef_frames_gpu), intrinsics.atomic_load(&cef_frames_cpu)
	iris_cpu := f64(ticks - perf.ticks) / CLK / dt * 100
	gfps, cfps := f64(gpu - perf.gpu) / dt, f64(cpu - perf.cpu) / dt
	path := cef_gpu_frames ? "GPU(dmabuf)" : "CPU(OnPaint)"
	kids := chromium_descendants(context.temp_allocator)
	by_kind := make(map[string]f64, 8, context.temp_allocator)
	for k in kids {
		stat, err := os.read_entire_file(fmt.tprintf("/proc/%d/stat", k.pid), context.temp_allocator)
		if err != nil do continue
		cmd, _ := os.read_entire_file(fmt.tprintf("/proc/%d/cmdline", k.pid), context.temp_allocator)
		kind := "browser"
		for part in strings.split(string(cmd), "\x00", context.temp_allocator) {
			if strings.has_prefix(part, "--type=") do kind = part[7:]
		}
		t := cpu_ticks(string(stat))
		key := k.pid
		prev := perf_prev[key] or_else t
		perf_prev[key] = t
		pct := f64(t - prev) / CLK / dt * 100
		by_kind[kind] += pct
	}
	kinds := strings.builder_make(context.temp_allocator)
	for kind, pct in by_kind do fmt.sbprintf(&kinds, " %s %.0f%%", kind, pct)
	fmt.eprintfln("iris: perf: %.1f frames/s (%.1f gpu, %.1f cpu), path %s (step %d), Iris cpu %.0f%%, own GL %s%s, %d chromium processes, cpu by kind:%s",
		gfps + cfps, gfps, cfps, path, cef_gpu_level, iris_cpu, rnd_renderer, rnd_software ? " (SOFTWARE)" : "", len(kids), strings.to_string(kinds))
	perf.at, perf.gpu, perf.cpu, perf.ticks = now, gpu, cpu, ticks
}

@(private = "file") perf_prev: map[i32]u64
