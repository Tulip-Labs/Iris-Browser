#!/bin/sh
# wl/protocols_shell.odin from protocols/*.xml: what the Iris browser's
# wl/protocols.odin (copied here unchanged, CI checks it) does not have.
# Needs only python3: the core interfaces it refers to are in protocols.odin.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
files=""
for x in $(cat "$here/tools/protocols.txt"); do files="$files $here/protocols/$x.xml"; done
python3 "$here/tools/gen_wayland.py" --extern wl_surface,wl_output,wl_buffer,wl_pointer,xdg_popup --init _init_types_shell \
	"$here/wl/protocols_shell.odin" $files
