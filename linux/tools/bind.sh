#!/bin/sh
# src/soup_gen.odin from the system's headers
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
python3 "$here/tools/bind.py" "$here/src/soup_gen.odin" soup-3.0 "$here/tools/soup.txt" \
	--headers "libsoup/soup.h" --cflags "$(pkg-config --cflags libsoup-3.0)"
