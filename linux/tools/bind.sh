#!/bin/sh
# src/wpe_gen.odin and src/soup_gen.odin from the system's headers
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
have="WPERectangle WebKitColor"
python3 "$here/tools/bind.py" "$here/src/wpe_gen.odin" WPEWebKit-2.0 "$here/tools/wpe.txt" --have "$have" \
	--headers "wpe/webkit.h wpe/wpe-platform.h wpe/headless/wpe-headless.h" \
	--cflags "$(pkg-config --cflags wpe-webkit-2.0 wpe-platform-2.0 wpe-platform-headless-2.0)"
python3 "$here/tools/bind.py" "$here/src/soup_gen.odin" soup-3.0 "$here/tools/soup.txt" \
	--have "$have $(grep -o '^[A-Za-z_]* :: struct' "$here/src/wpe_gen.odin" | cut -d' ' -f1 | tr '\n' ' ')" \
	--headers "libsoup/soup.h" --cflags "$(pkg-config --cflags libsoup-3.0)"
