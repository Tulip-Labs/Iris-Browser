//go:build windows && servo

// Servo's pages in Iris's Windows window (see servo_linux.c for Linux): each
// page's frames go to the presenter (a child window of Iris's), and the
// pointer, the wheel and the keys of a Servo page go to it through the
// presenter's input. Servo runs on its own threads; the spin that drives it
// runs on a Go goroutine (lsvGoWake asks for one), and a page closes on that
// goroutine too, once Servo is done telling it things.

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "irisservo.h"

extern void lsvGoEvent(uint64_t id, int kind, char *text, int a, int b);
extern int lsvGoAllow(uint64_t id, char *url, char *page, char *kind);
extern int lsvGoNavigate(uint64_t id, char *url);
extern void lsvGoResult(uint64_t token, char *json);
extern void lsvGoFrame(uint64_t id, const uint8_t *rgba, int w, int h);
extern double lsvGoScale(void);
extern void lsvGoPlace(uint64_t id, int x, int y, int w, int h);
extern void lsvGoShow(uint64_t id, int on);
extern void lsvGoWinFocus(uint64_t id);
extern void lsvGoDrop(uint64_t id);
extern void lsvGoCursor(uint64_t id, char *name);
extern void lsvGoWake(void);
extern void lsvGoSetFocus(uint64_t id);
extern void lsvGoCloseLater(uint64_t id);

static void onWake(void) { lsvGoWake(); }

static void onEvent(uint64_t id, int kind, const char *text, int a, int b) {
	if (kind == 7) { // the cursor
		lsvGoCursor(id, (char *)text);
		return;
	}
	lsvGoEvent(id, kind, (char *)text, a, b);
}

static void onFrame(uint64_t id, const uint8_t *rgba, int w, int h) {
	if (!rgba || w <= 0 || h <= 0) return;
	lsvGoFrame(id, rgba, w, h);
}

static int onAllow(uint64_t id, const char *url, const char *page, const char *kind) {
	return lsvGoAllow(id, (char *)url, (char *)page, (char *)kind);
}

static int onNavigate(uint64_t id, const char *url) { return lsvGoNavigate(id, (char *)url); }

static void onResult(uint64_t token, const char *json) { lsvGoResult(token, (char *)json); }

// lsvStart starts Servo; 1 when it ran. The window belongs to the presenter
// (the Go side attaches it), and the scale comes from there too.
int lsvStart(uintptr_t view) {
	(void)view;
	return iris_servo_init(onWake, onEvent, onFrame, onAllow, onNavigate, onResult, (float)lsvGoScale());
}

int lsvOpen(uint64_t id, const char *url) {
	iris_servo_set_scale((float)lsvGoScale());
	int ok = iris_servo_open(id, 640, 480, url);
	onWake();
	return ok;
}

void lsvClose(uint64_t id) {
	lsvGoDrop(id);
	// Servo may be in the middle of telling this page something: it closes
	// on the spin thread, once that is over
	lsvGoCloseLater(id);
}

void lsvBounds(uint64_t id, int x, int y, int w, int h) {
	// the scale may have changed since the page opened: refresh it from the
	// window, as the Linux fix does
	iris_servo_set_scale((float)lsvGoScale());
	lsvGoPlace(id, x, y, w, h);
	iris_servo_resize(id, w, h);
	onWake();
}

void lsvShow(uint64_t id, int on) {
	lsvGoShow(id, on);
	iris_servo_show(id, on);
	onWake();
}

void lsvFocus(uint64_t id) {
	lsvGoSetFocus(id);
	lsvGoWinFocus(id);
	onWake();
}

void lsvWake(void) { onWake(); }
