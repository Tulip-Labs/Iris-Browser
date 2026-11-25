#!/bin/sh
# src/cef_capi.odin (structs, enums) and src/cef_gen.odin (functions) from
# the CEF headers. CEF_DIR: a CEF binary distribution (its include/ has
# capi/), or a chromiumembedded/cef checkout whose include/capi was
# generated (see abi/check-cef.sh). CEF_CFLAGS: extra flags (-I...).
# The pinned C API version: CEF_API_VERSION in src/cef_engine.odin.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${CEF_DIR:-}" ] || { echo "CEF_DIR is not set" >&2; exit 2; }
. "$here/tools/cef_headers.sh"
python3 "$here/tools/bind_structs.py" "$here/src/cef_capi.odin" "$here/tools/cef_structs.txt" --headers "$CEF_HEADERS" --cflags "$CEF_FLAGS"
have="cef_string_t $(grep -o '^cef_[a-z0-9_]* :: struct' "$here/src/cef_capi.odin" | cut -d' ' -f1 | tr '\n' ' ')"
python3 "$here/tools/bind.py" "$here/src/cef_gen.odin" cef "$here/tools/cef.txt" --have "$have" --headers "$CEF_HEADERS" --cflags "$CEF_FLAGS"
