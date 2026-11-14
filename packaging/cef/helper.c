// lite-go-helper: Chromium's other processes (pages, the GPU, the network).
// Lite Go starts them through this small program, so they do not load the
// whole browser. Built by build-litego.sh with the CEF distribution.

#include "include/cef_api_hash.h"
#include "include/capi/cef_app_capi.h"

int main(int argc, char **argv) {
	cef_api_hash(CEF_API_VERSION, 0);
	cef_main_args_t args = {argc, argv};
	return cef_execute_process(&args, NULL, NULL);
}
