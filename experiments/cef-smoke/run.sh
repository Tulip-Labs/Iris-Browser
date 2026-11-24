#!/bin/sh
# Run the smoke test: one page, one frame, 90 s. Needs CEF_DIR set.
# Prints PASS with the frame size, or FAIL with the reason; exit 0 / 1.
set -eu
cd "$(dirname "$0")"
[ -n "${CEF_DIR:-}" ] || { echo "CEF_DIR is not set" >&2; exit 2; }
export LD_LIBRARY_PATH="$CEF_DIR/Release${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec ./cef-smoke "$@"
