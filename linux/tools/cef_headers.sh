# shared by tools/bind_cef.sh and abi/check-cef.sh: the headers and flags
# the CEF bindings are generated from and checked against (API 15600 is
# CEF 156's frozen C API; src/cef_engine.odin passes it to cef_api_hash)
CEF_HEADERS="include/capi/cef_app_capi.h include/capi/cef_browser_capi.h include/capi/cef_client_capi.h include/capi/cef_request_context_capi.h include/capi/cef_render_process_handler_capi.h include/capi/cef_browser_process_handler_capi.h include/capi/cef_download_handler_capi.h include/capi/cef_image_capi.h include/capi/cef_process_message_capi.h include/capi/cef_values_capi.h include/capi/cef_menu_model_capi.h include/capi/cef_request_capi.h include/cef_api_hash.h include/internal/cef_string_types.h"
CEF_FLAGS="-I$CEF_DIR ${CEF_CFLAGS:-} -DCEF_API_VERSION=15600"
