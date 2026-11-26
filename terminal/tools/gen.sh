#!/bin/sh
# wl/protocols_terminal.odin from protocols/*.xml: what the Iris browser's
# wl/protocols.odin (copied here unchanged, CI checks it) does not have
# (the primary selection, for middle-click paste). Needs only python3.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
files=""
for x in $(cat "$here/tools/protocols.txt"); do files="$files $here/protocols/$x.xml"; done
python3 "$here/../shell/tools/gen_wayland.py" --extern wl_seat --init _init_types_terminal \
	"$here/wl/protocols_terminal.odin" $files
