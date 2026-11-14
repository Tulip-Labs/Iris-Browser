// lite-go-helper: Chromium's other processes (pages, the GPU, the network).
// Lite Go starts them through this small program, so they do not load the
// whole browser. Built by build-litego.sh with the CEF distribution.

#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "include/cef_api_hash.h"
#include "include/capi/cef_app_capi.h"

static const char *kind = "?";

// With LITEGO_CEF_VERBOSE set, a process that aborts says which one it was.
static void onAbort(int sig) {
	const char *m = "lite-go-helper: aborted, process type ";
	write(2, m, strlen(m));
	write(2, kind, strlen(kind));
	write(2, "\n", 1);
	signal(sig, SIG_DFL);
	raise(sig);
}

int main(int argc, char **argv) {
	for (int i = 1; i < argc; i++) {
		if (strncmp(argv[i], "--type=", 7) == 0) kind = argv[i] + 7;
	}
	if (getenv("LITEGO_CEF_VERBOSE")) {
		signal(SIGABRT, onAbort);
		signal(SIGSEGV, onAbort);
	}
	cef_api_hash(CEF_API_VERSION, 0);
	cef_main_args_t args = {argc, argv};
	return cef_execute_process(&args, NULL, NULL);
}
