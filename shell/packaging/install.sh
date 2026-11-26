#!/bin/sh
# Installs Iris Shell for you (no root): ~/.local/bin/iris-shell.
#   ./install.sh            install (and replace a running shell)
#   ./install.sh --remove   take it out of niri's settings, stop it, delete it
set -eu
here=$(cd "$(dirname "$0")" && pwd)
bin=${XDG_BIN_HOME:-$HOME/.local/bin}
case "${1:-}" in
--remove)
	if [ -x "$bin/iris-shell" ]; then
		"$bin/iris-shell" --remove-niri || true
		"$bin/iris-shell" --quit || true
		rm -f "$bin/iris-shell"
		echo "Iris Shell removed from $bin"
	else
		echo "Iris Shell is not installed in $bin"
	fi
	;;
"")
	[ -f "$here/iris-shell" ] || { echo "iris-shell is not next to install.sh" >&2; exit 1; }
	mkdir -p "$bin"
	# a new file, then a rename: a running shell keeps its old one until replaced
	install -m 755 "$here/iris-shell" "$bin/iris-shell.new"
	mv -f "$bin/iris-shell.new" "$bin/iris-shell"
	echo "Installed $("$bin/iris-shell" --version) in $bin"
	case ":$PATH:" in *":$bin:"*) ;; *) echo "Add $bin to your PATH (niri starts programs with it)." ;; esac
	echo "Next: iris-shell --setup-niri   (then sign in again, or run: iris-shell &)"
	;;
*) echo "usage: ./install.sh [--remove]" >&2; exit 2 ;;
esac
