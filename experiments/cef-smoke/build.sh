#!/bin/sh
# Build the CEF smoke test. Needs Odin (dev-2026-11a, as in linux.yml) and
# CEF_DIR set to the extracted CEF minimal distribution.
set -eu
cd "$(dirname "$0")"
[ -n "${CEF_DIR:-}" ] || { echo "CEF_DIR is not set" >&2; exit 2; }
[ -d "$CEF_DIR/Release" ] || { echo "CEF_DIR has no Release/ ($CEF_DIR)" >&2; exit 2; }
ODIN_BIN="${ODIN:-odin}"
command -v "$ODIN_BIN" >/dev/null || { echo "odin not found (ODIN=path to the odin binary)" >&2; exit 2; }
# rpath so the binary (and the subprocesses CEF re-execs from it) find libcef.so
"$ODIN_BIN" build . -out:cef-smoke -o:speed \
	-extra-linker-flags:"-L$CEF_DIR/Release -Wl,-rpath,$CEF_DIR/Release -pthread"
