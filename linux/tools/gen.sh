#!/bin/sh
# wl/protocols.odin from the system's protocol XML (tools/protocols.txt)
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
P=$(pkg-config --variable=pkgdatadir wayland-protocols)
W=$(pkg-config --variable=pkgdatadir wayland-scanner)
files="$W/wayland.xml"
for x in $(cat "$here/tools/protocols.txt"); do files="$files $P/$x.xml"; done
python3 "$here/tools/gen_wayland.py" "$here/wl/protocols.odin" $files
