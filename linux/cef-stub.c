// Stub libcef.so: the symbols the Iris CEF engine links against, for
// builds without a real CEF tree (the WPE build). The WPE binary never
// calls them, but the loader still needs the library at run time:
// --as-needed does not drop DT_NEEDED for symbols the binary references
// in code paths that never run (verified: a reference in dead code still
// records DT_NEEDED, and the binary refuses to start without the file).
// So the stub ships with the WPE build (and its Flatpak) as an inert
// placeholder — loaded, never called. The CEF build links the real
// libcef.so instead (CEF_DIR set), which the stub must never shadow:
// build.sh only uses the stub when CEF_DIR is unset.
//
// The signatures only have to name the symbols; the linker does not
// check types. They are kept close to the real ones so the stub reads
// honestly.
int cef_execute_process(void *a, void *b, void *c) { return -1; }
int cef_initialize(void *a, void *b, void *c, void *d) { return 0; }
void cef_shutdown(void) {}
const char *cef_api_hash(int v, int e) { (void)v; (void)e; return "stub"; }
void cef_do_message_loop_work(void) {}
void cef_run_message_loop(void) {}
void cef_quit_message_loop(void) {}
int cef_get_exit_code(void) { return 0; }
int cef_browser_host_create_browser(void *a, void *b, void *c, void *d, void *e, void *f) { return 0; }
void *cef_request_context_create_context(void *a, void *b) { return 0; }
int cef_string_utf8_to_utf16(const char *a, unsigned long b, void *c) { return 0; }
int cef_string_utf16_to_utf8(const void *a, unsigned long b, void *c) { return 0; }
void cef_string_utf16_clear(void *a) {}
void cef_string_utf8_clear(void *a) {}
unsigned long cef_string_list_size(void *a) { return 0; }
int cef_string_list_value(void *a, unsigned long b, void *c) { return 0; }
