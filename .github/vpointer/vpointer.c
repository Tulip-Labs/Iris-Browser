// A mouse for CI's headless Wayland screen, which has none: one virtual
// pointer that stays plugged in while the test runs (apps see a mouse from
// the start), driven by lines on its input:
//   at X Y W H    move to (X, Y) of a W x H layout (the screen in its units)
//   click         press and release the left button
//   wheel DY      scroll by DY
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>
#include "vp.h"

static struct wl_seat *seat;
static struct zwlr_virtual_pointer_manager_v1 *mgr;

static void global(void *d, struct wl_registry *r, uint32_t name, const char *iface, uint32_t v) {
	if (!strcmp(iface, wl_seat_interface.name)) seat = wl_registry_bind(r, name, &wl_seat_interface, 1);
	if (!strcmp(iface, zwlr_virtual_pointer_manager_v1_interface.name))
		mgr = wl_registry_bind(r, name, &zwlr_virtual_pointer_manager_v1_interface, 1);
}
static void gone(void *d, struct wl_registry *r, uint32_t name) {}
static const struct wl_registry_listener rl = {global, gone};

static uint32_t now(void) {
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return (uint32_t)(t.tv_sec * 1000 + t.tv_nsec / 1000000);
}

int main(void) {
	struct wl_display *dpy = wl_display_connect(NULL);
	if (!dpy) return fprintf(stderr, "vpointer: no Wayland display\n"), 1;
	struct wl_registry *reg = wl_display_get_registry(dpy);
	wl_registry_add_listener(reg, &rl, NULL);
	wl_display_roundtrip(dpy);
	if (!mgr) return fprintf(stderr, "vpointer: the compositor has no virtual pointers\n"), 1;
	struct zwlr_virtual_pointer_v1 *p = zwlr_virtual_pointer_manager_v1_create_virtual_pointer(mgr, seat);
	wl_display_roundtrip(dpy);
	fprintf(stderr, "vpointer: ready\n");
	char line[128];
	while (fgets(line, sizeof line, stdin)) {
		unsigned x, y, w, h;
		double dy;
		if (sscanf(line, "at %u %u %u %u", &x, &y, &w, &h) == 4) {
			zwlr_virtual_pointer_v1_motion_absolute(p, now(), x, y, w, h);
			zwlr_virtual_pointer_v1_frame(p);
		} else if (!strncmp(line, "click", 5)) {
			zwlr_virtual_pointer_v1_button(p, now(), 0x110, 1); // BTN_LEFT
			zwlr_virtual_pointer_v1_frame(p);
			wl_display_flush(dpy);
			usleep(60000);
			zwlr_virtual_pointer_v1_button(p, now(), 0x110, 0);
			zwlr_virtual_pointer_v1_frame(p);
		} else if (sscanf(line, "wheel %lf", &dy) == 1) {
			zwlr_virtual_pointer_v1_axis(p, now(), 0, wl_fixed_from_double(dy));
			zwlr_virtual_pointer_v1_frame(p);
		}
		wl_display_roundtrip(dpy);
		fprintf(stderr, "vpointer: %s", line);
	}
	return 0;
}
