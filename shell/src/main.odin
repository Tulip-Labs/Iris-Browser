// Iris Shell for niri: the background, and the glass in the gaps between
// windows. No menu, no launcher, no bar: niri keeps its own keys.
package shell

import "core:fmt"
import "core:os"
import "../logic"

USAGE :: `iris-shell %s: the background and window glass for niri

  iris-shell                start the shell (a running one is replaced)
  iris-shell --setup-niri   write ~/.config/niri/iris-shell.kdl, include it in
                            config.kdl (after a backup) and hide Waybar
  iris-shell --remove-niri  undo that: Waybar's line back, the include and
                            the file gone
  iris-shell --dark         dark mode for the desktop (GNOME color-scheme)
  iris-shell --light        light mode
  iris-shell --auto         no preference: the desktop's default
  iris-shell --quit         stop the running shell
  iris-shell --status       what the running shell is doing
  iris-shell --check        map the background, draw one frame, exit (for tests)
  iris-shell --version

Environment: IRIS_THEME=dark|light (fixes the theme), IRIS_SHELL_ANIM=0 (no
animation), IRIS_SHELL_CAPTURE=0 (never read a window's pixels),
IRIS_SHELL_FULLRES=1 (draw at full resolution), IRIS_SHELL_DEBUG=1.
`

main :: proc() {
	args := os.args[1:]
	if len(args) == 0 {
		os.exit(run(false))
	}
	switch args[0] {
	case "--version", "-V":
		fmt.printfln("iris-shell %s", VERSION)
	case "--help", "-h":
		fmt.printf(USAGE, VERSION)
	case "--check":
		os.exit(run(true))
	case "--setup-niri":
		os.exit(setup_cmd(false))
	case "--remove-niri":
		os.exit(setup_cmd(true))
	case "--dark", "--light", "--auto":
		os.exit(scheme_cmd(args[0][2:]))
	case "--quit":
		if _, ok := ctl_send("quit"); ok {
			fmt.println("iris-shell stopped")
		} else {
			fmt.println("iris-shell is not running")
		}
	case "--status":
		if reply, ok := ctl_send("status"); ok {
			fmt.print(reply)
		} else {
			fmt.println("iris-shell is not running")
			os.exit(1)
		}
	case:
		fmt.eprintf("iris-shell: unknown option %s\n\n", args[0])
		fmt.eprintf(USAGE, VERSION)
		os.exit(2)
	}
}

setup_cmd :: proc(remove: bool) -> int {
	dir := logic.niri_config_dir()
	if remove {
		res, err := logic.remove_niri(dir)
		if err != .None {
			fmt.eprintfln("iris-shell: cannot edit %s/config.kdl", dir)
			return 1
		}
		fmt.printfln("Removed Iris Shell from niri's settings in %s%s%s.", dir, res.added_include ? " (include taken out)" : "", res.hid_bar ? " (Waybar start line restored)" : "")
		return 0
	}
	res, err := logic.setup_niri(dir, look_read(logic.parse_scheme(env("IRIS_THEME"))).dark)
	switch err {
	case .None:
	case .No_Config:
		fmt.eprintfln("iris-shell: %s/config.kdl does not exist yet: start niri once (it writes one), then run this again", dir)
		return 1
	case .Io:
		fmt.eprintfln("iris-shell: cannot write in %s", dir)
		return 1
	}
	fmt.printfln("niri settings: %s/%s", dir, logic.KDL_NAME)
	if res.added_include do fmt.printfln("added `%s` to config.kdl (a copy of the old one is %s)", logic.INCLUDE_LINE, res.backup)
	if res.hid_bar do fmt.println("Waybar's start line is commented out (`iris-shell --remove-niri` puts it back)")
	if !res.added_include && !res.hid_bar do fmt.println("already set up")
	fmt.println("niri reloads its settings by itself; the shell starts with the next sign-in (or run `iris-shell &`).")
	return 0
}

scheme_cmd :: proc(name: string) -> int {
	s := logic.parse_scheme(name)
	ok := system_scheme(s)
	if !ok do fmt.eprintln("iris-shell: gsettings could not set color-scheme (is it installed?); the running shell is told anyway")
	// a running shell follows at once: it reads the desktop's setting again
	// (and only when gsettings could not set it, takes the scheme itself)
	if _, running := ctl_send(ok ? "reload" : name); !running && !ok do return 1
	fmt.printfln("theme: %s", name)
	return 0
}
