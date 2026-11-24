#!/bin/sh
# Regenerate cef_gen.odin from the CEF headers (tools/bind.py, cef.txt).
# Needs CEF_DIR set to the extracted CEF minimal distribution, and clang.
# Usage: ./gen.sh [output.odin]  (default: cef_gen.odin)
set -eu
cd "$(dirname "$0")"
[ -n "${CEF_DIR:-}" ] || { echo "CEF_DIR is not set" >&2; exit 2; }
OUT="${1:-cef_gen.odin}"
HAVE="cef_settings_t cef_window_info_t cef_browser_settings_t cef_client_t cef_render_handler_t cef_life_span_handler_t cef_load_handler_t cef_main_args_t cef_rect_t cef_string_t cef_string_utf16_t cef_base_ref_counted_t cef_browser_t cef_browser_host_t cef_request_context_settings_t"
python3 ../../linux/tools/bind.py "$OUT" cef cef.txt --package main --have "$HAVE" \
	--headers "include/capi/cef_app_capi.h include/capi/cef_browser_capi.h include/capi/cef_request_context_capi.h include/internal/cef_string_types.h include/cef_api_hash.h" \
	--cflags="-I$CEF_DIR"
