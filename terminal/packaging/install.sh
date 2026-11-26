#!/bin/sh
# Installs Iris Terminal for you (no root): ~/.local/bin/iris-terminal, its
# launcher entry and its icon. Works on Fedora Silverblue and Kinoite as it
# is: nothing is layered, nothing goes outside your home folder.
#   ./install.sh            install
#   ./install.sh --remove   undo --setup-niri and --setup-zsh, delete it all
set -eu
here=$(cd "$(dirname "$0")" && pwd)
bin=${XDG_BIN_HOME:-$HOME/.local/bin}
data=${XDG_DATA_HOME:-$HOME/.local/share}
app=io.github.tulip_labs.IrisTerminal
case "${1:-}" in
--remove)
	if [ -x "$bin/iris-terminal" ]; then
		"$bin/iris-terminal" --remove-niri || true
		"$bin/iris-terminal" --remove-zsh || true
	fi
	rm -f "$bin/iris-terminal" "$data/applications/$app.desktop" "$data/icons/hicolor/scalable/apps/$app.svg"
	command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$data/applications" >/dev/null 2>&1 || true
	echo "Iris Terminal removed from $bin (your settings in ~/.config/iris-terminal are kept)"
	;;
"")
	[ -f "$here/iris-terminal" ] || { echo "iris-terminal is not next to install.sh" >&2; exit 1; }
	mkdir -p "$bin" "$data/applications" "$data/icons/hicolor/scalable/apps"
	# a new file, then a rename: a running terminal keeps its old one
	install -m 755 "$here/iris-terminal" "$bin/iris-terminal.new"
	mv -f "$bin/iris-terminal.new" "$bin/iris-terminal"
	install -m 644 "$here/$app.svg" "$data/icons/hicolor/scalable/apps/$app.svg"
	sed "s|^Exec=iris-terminal|Exec=$bin/iris-terminal|" "$here/$app.desktop" > "$data/applications/$app.desktop"
	chmod 644 "$data/applications/$app.desktop"
	command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$data/applications" >/dev/null 2>&1 || true
	echo "Installed $("$bin/iris-terminal" --version) in $bin"
	case ":$PATH:" in *":$bin:"*) ;; *) echo "Add $bin to your PATH (niri starts programs with it)." ;; esac
	echo "Next: iris-terminal --setup-niri   (rounded glass, blur on niri 26.04+)"
	echo "      iris-terminal --setup-zsh    (the refined zsh)"
	echo "      iris-terminal --install-fonts   (MesloLGS NF, if you want the prompt's symbols)"
	;;
*) echo "usage: ./install.sh [--remove]" >&2; exit 2 ;;
esac
