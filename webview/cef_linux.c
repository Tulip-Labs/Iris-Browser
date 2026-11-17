//go:build linux && webkit

// The Linux side of Lite Go's web engine on Chromium, through CEF (the
// Chromium Embedded Framework).
//
// Lite Go's window is a GTK window (cmd/litego/gtk_linux.c) with a GtkLayout:
// the interface is drawn by Gio in a GL area, and each page is a GtkDrawingArea
// in the layout, over it. CEF renders the pages off screen ("windowless"): it
// hands over the pixels of each page, and this file paints them and passes
// the pointer, wheel and keys back. Nothing here needs X11: it runs on
// Wayland (and on X11 too).
//
// It speaks the same small protocol to Go as the WebKitGTK engine
// (webview_linux.c): lgxCall with an operation, and lgxGo* callbacks. CEF's
// UI thread is GTK's main thread (an external message pump), so everything
// here runs there, except the resource checks, which CEF makes on its IO
// thread (views are found under a lock).

#include <gtk/gtk.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "include/cef_api_hash.h"
#include "include/cef_version.h"
#include "include/capi/cef_app_capi.h"
#include "include/capi/cef_browser_capi.h"
#include "include/capi/cef_client_capi.h"
#include "include/capi/cef_command_line_capi.h"
#include "include/capi/cef_display_handler_capi.h"
#include "include/capi/cef_download_handler_capi.h"
#include "include/capi/cef_download_item_capi.h"
#include "include/capi/cef_frame_capi.h"
#include "include/capi/cef_keyboard_handler_capi.h"
#include "include/capi/cef_life_span_handler_capi.h"
#include "include/capi/cef_load_handler_capi.h"
#include "include/capi/cef_permission_handler_capi.h"
#include "include/capi/cef_render_handler_capi.h"
#include "include/capi/cef_request_capi.h"
#include "include/capi/cef_request_context_capi.h"
#include "include/capi/cef_request_handler_capi.h"
#include "include/capi/cef_resource_request_handler_capi.h"
#include "include/capi/cef_context_menu_handler_capi.h"
#include "include/capi/cef_jsdialog_handler_capi.h"

enum { OP_NEW = 1, OP_NAV, OP_BACK, OP_FWD, OP_RELOAD, OP_STOP, OP_BOUNDS, OP_SHOW, OP_FOCUS, OP_EVAL, OP_MUTE, OP_CLOSE, OP_SCRIPT, OP_PROFILE, OP_PRIVATE, OP_BLOCKLIST, OP_ZOOM, OP_DLCANCEL };

extern void lgxGoCreated(uintptr_t cb, int ok);
extern void lgxGoURL(uintptr_t id, char *u);
extern void lgxGoTitle(uintptr_t id, char *t);
extern void lgxGoLoading(uintptr_t id, int on, int back, int fwd);
extern char *lgxGoDecide(uintptr_t id, char *u, int gesture);
extern uintptr_t lgxGoPopup(uintptr_t id, char *u);
extern void lgxGoFullscreen(uintptr_t id, int on);
extern void lgxGoCrashed(uintptr_t id);
extern void lgxGoAudio(uintptr_t id, int on);
extern int lgxGoKey(uintptr_t id, int ch, int vk, int ctrl, int shift, int alt);
extern void lgxGoResult(uintptr_t cb, char *res);
extern void lgxGoFocus(uintptr_t id);
extern void lgxGoDownload(uintptr_t id, uintptr_t view, int state, char *url, char *path, long long total, long long got);
extern int lgxGoAllow(uintptr_t id, char *url, char *page, char *kind);
extern void lgxGoBlocked(uintptr_t id, char *url);

enum { DL_ACTIVE = 0, DL_DONE = 2, DL_FAILED = 3, DL_CANCELED = 4 };

typedef struct {
	uintptr_t id;
	cef_browser_t *browser; // NULL until created
	int bid;                // the browser's identifier
	GtkWidget *area;        // where the page is painted, in the layout
	GtkIMContext *im;       // dead keys and input methods
	cairo_surface_t *page, *popup;
	cef_rect_t popupRect;
	int popupShown;
	int w, h;      // size in GTK units
	int sf;        // the scale Chromium was last told
	int shown;
	char *profile;
	int priv, sandbox;
	GSList *scripts; // run at the start of every page
	char *startURL;  // a popup's address, or the first navigation before the browser exists
	uintptr_t createdCB;
	int muted;
	double zoom;
	char *pageURL; // for the shield's first-party checks
	int closing;
} LV;

static GtkLayout *host;
static char *dataDir;
static GHashTable *views;    // id -> LV*
static GHashTable *byBrowser; // browser identifier -> LV*
static GHashTable *contexts; // profile key -> cef_request_context_t*
static GHashTable *downloads; // download id -> cef_download_item_callback_t* (only while active)
static GQueue pending = G_QUEUE_INIT; // pages whose browser is being made, oldest first
static GMutex lock;          // views as seen from CEF's IO thread
static int memTotalMB;
static int started;

void lgxSetMemory(int totalMB) { memTotalMB = totalMB; }

// ---- strings ----

static void setStr(cef_string_t *dst, const char *s) {
	if (!s) s = "";
	cef_string_utf8_to_utf16(s, strlen(s), dst);
}

static char *getStr(const cef_string_t *s) {
	if (!s || !s->str) return g_strdup("");
	cef_string_utf8_t out = {0};
	cef_string_utf16_to_utf8(s->str, s->length, &out);
	char *r = g_strndup(out.str ? out.str : "", out.length);
	cef_string_utf8_clear(&out);
	return r;
}

static char *takeStr(cef_string_userfree_t s) {
	char *r = getStr(s);
	if (s) cef_string_userfree_free(s);
	return r;
}

// Objects CEF hands to a callback carry a reference the callback gives back.
#define RELEASE(o) do { if (o) (o)->base.release(&(o)->base); } while (0)

// The handlers are one static object each, shared by every page: their
// reference counts never matter.
static void CEF_CALLBACK noRef(cef_base_ref_counted_t *b) {}
static int CEF_CALLBACK noRelease(cef_base_ref_counted_t *b) { return 0; }
static int CEF_CALLBACK oneRef(cef_base_ref_counted_t *b) { return 1; }
#define STATIC_BASE(obj)                                                                                                 \
	do {                                                                                                                 \
		(obj).base.size = sizeof(obj);                                                                                   \
		(obj).base.add_ref = noRef;                                                                                      \
		(obj).base.release = noRelease;                                                                                  \
		(obj).base.has_one_ref = oneRef;                                                                                 \
		(obj).base.has_at_least_one_ref = oneRef;                                                                        \
	} while (0)

static LV *lv(uintptr_t id, int make) {
	LV *v = g_hash_table_lookup(views, (gpointer)id);
	if (!v && make) {
		v = g_new0(LV, 1);
		v->id = id;
		v->zoom = 1;
		g_mutex_lock(&lock);
		g_hash_table_insert(views, (gpointer)id, v);
		g_mutex_unlock(&lock);
	}
	return v;
}

// of(browser) finds the page of a browser; it releases the reference the
// callback received.
static LV *of(cef_browser_t *b) {
	if (!b) return NULL;
	int bid = b->get_identifier(b);
	g_mutex_lock(&lock);
	LV *v = g_hash_table_lookup(byBrowser, GINT_TO_POINTER(bid));
	g_mutex_unlock(&lock);
	RELEASE(b);
	return v;
}

static cef_browser_host_t *hostOf(LV *v) { return v && v->browser ? v->browser->get_host(v->browser) : NULL; }

static int scaleOf(void) {
	int sf = host ? gtk_widget_get_scale_factor(GTK_WIDGET(host)) : 1;
	return sf < 1 ? 1 : sf;
}

// ---- the message pump: CEF's work runs from GTK's main loop ----

static guint pumpTimer;

static gboolean pumpWork(gpointer d) {
	pumpTimer = 0;
	cef_do_message_loop_work();
	return G_SOURCE_REMOVE;
}

static gboolean pumpTick(gpointer d) {
	cef_do_message_loop_work();
	return G_SOURCE_CONTINUE;
}

static gboolean schedulePump(gpointer d) {
	int64_t ms = (int64_t)(intptr_t)d;
	if (pumpTimer) g_source_remove(pumpTimer);
	pumpTimer = ms <= 0 ? g_idle_add_full(G_PRIORITY_DEFAULT, pumpWork, NULL, NULL) : g_timeout_add((guint)ms, pumpWork, NULL);
	return G_SOURCE_REMOVE;
}

static void CEF_CALLBACK onSchedulePump(cef_browser_process_handler_t *self, int64_t delay) {
	if (delay > 50) delay = 50;
	g_main_context_invoke(NULL, schedulePump, (gpointer)(intptr_t)delay);
}

static int noSandbox;

static int fileSays(const char *path, const char *want) {
	char *b = NULL;
	int r = g_file_get_contents(path, &b, NULL, NULL) && g_str_has_prefix(g_strstrip(b), want);
	g_free(b);
	return r;
}

// sandboxMissing says whether Chromium has no sandbox it can use here: the
// packages install chrome-sandbox setuid root; a home-folder copy relies on
// user namespaces, which some systems turn off (Ubuntu 24.04's AppArmor).
// Without either, the pages still run, only without Chromium's sandbox.
static int sandboxMissing(const char *bin) {
	if (g_getenv("LITEGO_NO_SANDBOX")) return 1;
	char *helper = g_build_filename(bin, "chrome-sandbox", NULL);
	struct stat st;
	int setuid = stat(helper, &st) == 0 && st.st_uid == 0 && (st.st_mode & S_ISUID);
	g_free(helper);
	if (setuid) return 0;
	if (fileSays("/proc/sys/kernel/unprivileged_userns_clone", "0")) return 1;
	if (fileSays("/proc/sys/kernel/apparmor_restrict_unprivileged_userns", "1")) return 1;
	if (fileSays("/proc/sys/user/max_user_namespaces", "0")) return 1;
	return 0;
}

static void CEF_CALLBACK onCommandLine(cef_app_t *self, const cef_string_t *type, cef_command_line_t *cl) {
	if (type && type->length) return; // only the browser process
	cef_string_t k = {0}, val = {0};
	// Wayland, always (Lite Go's window is a Wayland window)
	setStr(&k, "ozone-platform");
	setStr(&val, g_getenv("WAYLAND_DISPLAY") || !g_getenv("DISPLAY") ? "wayland" : "x11");
	cl->append_switch_with_value(cl, &k, &val);
	cef_string_clear(&k);
	cef_string_clear(&val);
	// media keys and the like belong to the desktop, not to the pages
	setStr(&k, "disable-features");
	setStr(&val, "HardwareMediaKeyHandling,MediaSessionService,BackForwardCache,Translate,OptimizationHints,MediaRouter,"
	             "DialMediaRouteProvider,AutofillServerCommunication,CertificateTransparencyComponentUpdater,InterestFeedContentSuggestions,"
	             "IsolateOrigins,site-per-process,SpareRendererForSitePerProcess,PrefetchPrivacyChanges,Prerender2,LensOverlay,"
	             "GlobalMediaControls,PrivacySandboxSettings4,FedCm");
	cl->append_switch_with_value(cl, &k, &val);
	cef_string_clear(&k);
	cef_string_clear(&val);
	// Lighter Chromium. Pages of one site share a process, and at most a few
	// page processes run (on 8 GB and less, three), at the cost of the strict
	// one-process-per-site isolation Chrome uses. Nothing runs that a browser
	// without Google's services and extensions does not need: background
	// networking, component updates, translate, the page-to-page cache that
	// keeps old pages in memory, media routing, crash reports.
	struct {
		const char *k, *v;
	} flags[] = {
		{"process-per-site", NULL},
		{"renderer-process-limit", memTotalMB > 0 && memTotalMB <= 8192 ? "3" : "5"},
		{"disable-background-networking", NULL},
		{"disable-component-update", NULL},
		{"disable-default-apps", NULL},
		{"disable-sync", NULL},
		{"disable-breakpad", NULL},
		{"disable-domain-reliability", NULL},
		{"no-pings", NULL},
		{"no-first-run", NULL},
		{"disable-spell-checking", NULL},
		{"disable-gpu-shader-disk-cache", NULL},
		{"disk-cache-size", "104857600"},
		{"js-flags", memTotalMB > 0 && memTotalMB <= 8192 ? "--optimize-for-size" : NULL},
	};
	for (size_t i = 0; i < sizeof flags / sizeof flags[0]; i++) {
		if (strcmp(flags[i].k, "js-flags") == 0 && !flags[i].v) continue;
		setStr(&k, flags[i].k);
		if (flags[i].v) {
			setStr(&val, flags[i].v);
			cl->append_switch_with_value(cl, &k, &val);
			cef_string_clear(&val);
		} else {
			cl->append_switch(cl, &k);
		}
		cef_string_clear(&k);
	}
	const char *extra = g_getenv("LITEGO_CEF_ARGS"); // for diagnosis: --name or --name=value, separated by spaces
	if (extra) {
		char **sw = g_strsplit(extra, " ", -1);
		for (char **p = sw; *p; p++) {
			const char *a = *p;
			while (*a == '-') a++;
			if (!*a) continue;
			char *eq = strchr(a, '=');
			if (eq) {
				char *name = g_strndup(a, eq - a);
				setStr(&k, name);
				setStr(&val, eq + 1);
				cl->append_switch_with_value(cl, &k, &val);
				cef_string_clear(&val);
				g_free(name);
			} else {
				setStr(&k, a);
				cl->append_switch(cl, &k);
			}
			cef_string_clear(&k);
		}
		g_strfreev(sw);
	}
	if (noSandbox) {
		setStr(&k, "no-sandbox");
		cl->append_switch(cl, &k);
		cef_string_clear(&k);
	}
}

static cef_app_t app;
static cef_browser_process_handler_t bph;
static cef_browser_process_handler_t *CEF_CALLBACK getBPH(cef_app_t *self) { return &bph; }

// ---- painting ----

static gboolean onDraw(GtkWidget *w, cairo_t *cr, LV *v) {
	if (v->page) {
		// one page pixel to one screen pixel: no smoothing, so text stays sharp
		cairo_set_source_surface(cr, v->page, 0, 0);
		cairo_pattern_set_filter(cairo_get_source(cr), CAIRO_FILTER_NEAREST);
		cairo_paint(cr);
	} else {
		cairo_set_source_rgb(cr, 1, 1, 1);
		cairo_paint(cr);
	}
	if (v->popup && v->popupShown) {
		int sf = scaleOf();
		cairo_set_source_surface(cr, v->popup, v->popupRect.x, v->popupRect.y);
		cairo_pattern_set_filter(cairo_get_source(cr), CAIRO_FILTER_NEAREST);
		cairo_rectangle(cr, v->popupRect.x, v->popupRect.y, (double)v->popupRect.width, (double)v->popupRect.height);
		cairo_fill(cr);
		(void)sf;
	}
	return TRUE;
}

// copyInto copies a frame, only the parts that changed when the frame is the
// same size as the last one; scale is pixels per GTK unit of that frame (taken
// from the frame itself, so a frame made before a scale change still fits).
// It returns whether the whole frame was copied.
static int copyInto(cairo_surface_t **dst, const void *buf, int w, int h, double scale, size_t n, const cef_rect_t *dirty) {
	double sf = scale > 0 ? scale : scaleOf();
	// a scale a hair off a whole number is that number (no resampling)
	if (fabs(sf - round(sf)) < 0.02) sf = round(sf);
	int whole = 0;
	if (!*dst || cairo_image_surface_get_width(*dst) != w || cairo_image_surface_get_height(*dst) != h) {
		if (*dst) cairo_surface_destroy(*dst);
		*dst = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h);
		whole = 1;
	}
	cairo_surface_set_device_scale(*dst, sf, sf);
	cairo_surface_flush(*dst);
	unsigned char *d = cairo_image_surface_get_data(*dst);
	int stride = cairo_image_surface_get_stride(*dst);
	const unsigned char *s = buf;
	if (whole || n == 0 || !dirty) {
		if (stride == w * 4) {
			memcpy(d, s, (size_t)w * h * 4);
		} else {
			for (int y = 0; y < h; y++) memcpy(d + (size_t)y * stride, s + (size_t)y * w * 4, (size_t)w * 4);
		}
		whole = 1;
	} else {
		for (size_t i = 0; i < n; i++) {
			cef_rect_t r = dirty[i];
			if (r.x < 0) r.width += r.x, r.x = 0;
			if (r.y < 0) r.height += r.y, r.y = 0;
			if (r.x + r.width > w) r.width = w - r.x;
			if (r.y + r.height > h) r.height = h - r.y;
			if (r.width <= 0 || r.height <= 0) continue;
			for (int y = r.y; y < r.y + r.height; y++)
				memcpy(d + (size_t)y * stride + (size_t)r.x * 4, s + ((size_t)y * w + r.x) * 4, (size_t)r.width * 4);
		}
	}
	cairo_surface_mark_dirty(*dst);
	return whole;
}

static void CEF_CALLBACK onPaint(cef_render_handler_t *self, cef_browser_t *b, cef_paint_element_type_t type, size_t n, cef_rect_t const *dirty,
                                 const void *buf, int w, int h) {
	LV *v = of(b);
	if (!v || !v->area) return;
	if (type == PET_POPUP) {
		copyInto(&v->popup, buf, w, h, v->popupRect.width > 0 ? (double)w / v->popupRect.width : 0, 0, NULL);
		gtk_widget_queue_draw(v->area);
		return;
	}
	double sf = v->w > 0 ? (double)w / v->w : 0;
	if (copyInto(&v->page, buf, w, h, sf, n, dirty) || sf <= 0 || v->popupShown) {
		gtk_widget_queue_draw(v->area);
		return;
	}
	// redraw only what changed (in GTK units, rounded outward)
	for (size_t i = 0; i < n; i++) {
		int x0 = (int)floor(dirty[i].x / sf), y0 = (int)floor(dirty[i].y / sf);
		int x1 = (int)ceil((dirty[i].x + dirty[i].width) / sf), y1 = (int)ceil((dirty[i].y + dirty[i].height) / sf);
		gtk_widget_queue_draw_area(v->area, x0, y0, x1 - x0, y1 - y0);
	}
}

static void CEF_CALLBACK getViewRect(cef_render_handler_t *self, cef_browser_t *b, cef_rect_t *r) {
	LV *v = of(b);
	r->x = r->y = 0;
	r->width = v && v->w > 0 ? v->w : 640;
	r->height = v && v->h > 0 ? v->h : 480;
}

static int CEF_CALLBACK getScreenInfo(cef_render_handler_t *self, cef_browser_t *b, cef_screen_info_t *si) {
	LV *v = of(b);
	// the scale of the page's own area once it is on screen (the window's before)
	int sf = v && v->area && gtk_widget_get_realized(v->area) ? gtk_widget_get_scale_factor(v->area) : scaleOf();
	si->device_scale_factor = (float)(sf < 1 ? 1 : sf);
	return 1;
}

static int CEF_CALLBACK getScreenPoint(cef_render_handler_t *self, cef_browser_t *b, int x, int y, int *sx, int *sy) {
	RELEASE(b);
	*sx = x;
	*sy = y;
	return 1;
}

static void CEF_CALLBACK onPopupShow(cef_render_handler_t *self, cef_browser_t *b, int show) {
	LV *v = of(b);
	if (!v) return;
	v->popupShown = show;
	if (!show && v->popup) {
		cairo_surface_destroy(v->popup);
		v->popup = NULL;
	}
	if (v->area) gtk_widget_queue_draw(v->area);
}

static void CEF_CALLBACK onPopupSize(cef_render_handler_t *self, cef_browser_t *b, const cef_rect_t *r) {
	LV *v = of(b);
	if (v) v->popupRect = *r;
}

static cef_render_handler_t renderH;

// ---- input ----

static uint32_t modsOf(guint state) {
	uint32_t m = 0;
	if (state & GDK_SHIFT_MASK) m |= EVENTFLAG_SHIFT_DOWN;
	if (state & GDK_CONTROL_MASK) m |= EVENTFLAG_CONTROL_DOWN;
	if (state & GDK_MOD1_MASK) m |= EVENTFLAG_ALT_DOWN;
	if (state & GDK_BUTTON1_MASK) m |= EVENTFLAG_LEFT_MOUSE_BUTTON;
	if (state & GDK_BUTTON2_MASK) m |= EVENTFLAG_MIDDLE_MOUSE_BUTTON;
	if (state & GDK_BUTTON3_MASK) m |= EVENTFLAG_RIGHT_MOUSE_BUTTON;
	if (state & GDK_LOCK_MASK) m |= EVENTFLAG_CAPS_LOCK_ON;
	return m;
}

static gboolean onButton(GtkWidget *w, GdkEventButton *e, LV *v) {
	cef_browser_host_t *h = hostOf(v);
	if (!h) return FALSE;
	if (e->type == GDK_BUTTON_PRESS) {
		gtk_widget_grab_focus(w);
		h->set_focus(h, 1);
		lgxGoFocus(v->id);
	}
	cef_mouse_button_type_t bt = MBT_LEFT;
	if (e->button == 2) bt = MBT_MIDDLE;
	if (e->button == 3) bt = MBT_RIGHT;
	if (e->button == 8 || e->button == 9) {
		// the mouse's back and forward buttons
		if (e->type == GDK_BUTTON_PRESS && v->browser) {
			if (e->button == 8) v->browser->go_back(v->browser);
			else v->browser->go_forward(v->browser);
		}
		RELEASE(h);
		return TRUE;
	}
	int clicks = 1;
	if (e->type == GDK_2BUTTON_PRESS) clicks = 2;
	if (e->type == GDK_3BUTTON_PRESS) clicks = 3;
	cef_mouse_event_t me = {(int)e->x, (int)e->y, modsOf(e->state)};
	h->send_mouse_click_event(h, &me, bt, e->type == GDK_BUTTON_RELEASE, clicks);
	RELEASE(h);
	return TRUE;
}

static gboolean onMotion(GtkWidget *w, GdkEventMotion *e, LV *v) {
	cef_browser_host_t *h = hostOf(v);
	if (!h) return FALSE;
	cef_mouse_event_t me = {(int)e->x, (int)e->y, modsOf(e->state)};
	h->send_mouse_move_event(h, &me, 0);
	RELEASE(h);
	return TRUE;
}

static gboolean onLeave(GtkWidget *w, GdkEventCrossing *e, LV *v) {
	cef_browser_host_t *h = hostOf(v);
	if (!h) return FALSE;
	cef_mouse_event_t me = {(int)e->x, (int)e->y, modsOf(e->state)};
	h->send_mouse_move_event(h, &me, 1);
	RELEASE(h);
	return FALSE;
}

static gboolean onScroll(GtkWidget *w, GdkEventScroll *e, LV *v) {
	cef_browser_host_t *h = hostOf(v);
	if (!h) return FALSE;
	int dx = 0, dy = 0;
	const int tick = 40; // pixels for one notch of the wheel
	switch (e->direction) {
	case GDK_SCROLL_UP: dy = tick; break;
	case GDK_SCROLL_DOWN: dy = -tick; break;
	case GDK_SCROLL_LEFT: dx = tick; break;
	case GDK_SCROLL_RIGHT: dx = -tick; break;
	case GDK_SCROLL_SMOOTH:
		dx = (int)lround(-e->delta_x * tick);
		dy = (int)lround(-e->delta_y * tick);
		break;
	}
	uint32_t m = modsOf(e->state);
	if ((m & EVENTFLAG_SHIFT_DOWN) && dx == 0) {
		dx = dy; // Shift + wheel scrolls sideways
		dy = 0;
	}
	cef_mouse_event_t me = {(int)e->x, (int)e->y, m};
	h->send_mouse_wheel_event(h, &me, dx, dy);
	RELEASE(h);
	return TRUE;
}

// winKey maps a GDK key to the Windows key code Chromium works with.
static int winKey(guint kv) {
	if (kv >= GDK_KEY_a && kv <= GDK_KEY_z) return 'A' + (kv - GDK_KEY_a);
	if (kv >= GDK_KEY_A && kv <= GDK_KEY_Z) return 'A' + (kv - GDK_KEY_A);
	if (kv >= GDK_KEY_0 && kv <= GDK_KEY_9) return '0' + (kv - GDK_KEY_0);
	if (kv >= GDK_KEY_F1 && kv <= GDK_KEY_F24) return 0x70 + (kv - GDK_KEY_F1);
	if (kv >= GDK_KEY_KP_0 && kv <= GDK_KEY_KP_9) return 0x60 + (kv - GDK_KEY_KP_0);
	switch (kv) {
	case GDK_KEY_BackSpace: return 0x08;
	case GDK_KEY_Tab: case GDK_KEY_ISO_Left_Tab: return 0x09;
	case GDK_KEY_Return: case GDK_KEY_KP_Enter: return 0x0D;
	case GDK_KEY_Shift_L: case GDK_KEY_Shift_R: return 0x10;
	case GDK_KEY_Control_L: case GDK_KEY_Control_R: return 0x11;
	case GDK_KEY_Alt_L: case GDK_KEY_Alt_R: case GDK_KEY_ISO_Level3_Shift: return 0x12;
	case GDK_KEY_Pause: return 0x13;
	case GDK_KEY_Caps_Lock: return 0x14;
	case GDK_KEY_Escape: return 0x1B;
	case GDK_KEY_space: return 0x20;
	case GDK_KEY_Page_Up: case GDK_KEY_KP_Page_Up: return 0x21;
	case GDK_KEY_Page_Down: case GDK_KEY_KP_Page_Down: return 0x22;
	case GDK_KEY_End: case GDK_KEY_KP_End: return 0x23;
	case GDK_KEY_Home: case GDK_KEY_KP_Home: return 0x24;
	case GDK_KEY_Left: case GDK_KEY_KP_Left: return 0x25;
	case GDK_KEY_Up: case GDK_KEY_KP_Up: return 0x26;
	case GDK_KEY_Right: case GDK_KEY_KP_Right: return 0x27;
	case GDK_KEY_Down: case GDK_KEY_KP_Down: return 0x28;
	case GDK_KEY_Print: return 0x2C;
	case GDK_KEY_Insert: case GDK_KEY_KP_Insert: return 0x2D;
	case GDK_KEY_Delete: case GDK_KEY_KP_Delete: return 0x2E;
	case GDK_KEY_Super_L: return 0x5B;
	case GDK_KEY_Super_R: return 0x5C;
	case GDK_KEY_Menu: return 0x5D;
	case GDK_KEY_KP_Multiply: return 0x6A;
	case GDK_KEY_KP_Add: return 0x6B;
	case GDK_KEY_KP_Subtract: return 0x6D;
	case GDK_KEY_KP_Decimal: return 0x6E;
	case GDK_KEY_KP_Divide: return 0x6F;
	case GDK_KEY_Num_Lock: return 0x90;
	case GDK_KEY_Scroll_Lock: return 0x91;
	case GDK_KEY_semicolon: case GDK_KEY_colon: return 0xBA;
	case GDK_KEY_plus: case GDK_KEY_equal: return 0xBB;
	case GDK_KEY_comma: case GDK_KEY_less: return 0xBC;
	case GDK_KEY_minus: case GDK_KEY_underscore: return 0xBD;
	case GDK_KEY_period: case GDK_KEY_greater: return 0xBE;
	case GDK_KEY_slash: case GDK_KEY_question: return 0xBF;
	case GDK_KEY_grave: case GDK_KEY_asciitilde: return 0xC0;
	case GDK_KEY_bracketleft: case GDK_KEY_braceleft: return 0xDB;
	case GDK_KEY_backslash: case GDK_KEY_bar: return 0xDC;
	case GDK_KEY_bracketright: case GDK_KEY_braceright: return 0xDD;
	case GDK_KEY_apostrophe: case GDK_KEY_quotedbl: return 0xDE;
	case GDK_KEY_ntilde: case GDK_KEY_Ntilde: return 0xC0;
	case GDK_KEY_Back: return 0xA6;
	case GDK_KEY_Forward: return 0xA7;
	case GDK_KEY_AudioMute: return 0xAD;
	case GDK_KEY_AudioLowerVolume: return 0xAE;
	case GDK_KEY_AudioRaiseVolume: return 0xAF;
	}
	return 0;
}

static void sendChars(LV *v, const char *text, uint32_t mods) {
	cef_browser_host_t *h = hostOf(v);
	if (!h) return;
	glong n = 0;
	gunichar2 *u = g_utf8_to_utf16(text, -1, NULL, &n, NULL);
	for (glong i = 0; u && i < n; i++) {
		cef_key_event_t k = {0};
		k.size = sizeof k;
		k.type = KEYEVENT_CHAR;
		k.modifiers = mods;
		k.windows_key_code = u[i];
		k.character = u[i];
		k.unmodified_character = u[i];
		h->send_key_event(h, &k);
	}
	g_free(u);
	RELEASE(h);
}

static void onCommit(GtkIMContext *im, const char *text, LV *v) { sendChars(v, text, 0); }

static gboolean onKey(GtkWidget *w, GdkEventKey *e, LV *v) {
	cef_browser_host_t *h = hostOf(v);
	if (!h) return FALSE;
	int ctrl = (e->state & GDK_CONTROL_MASK) != 0, shift = (e->state & GDK_SHIFT_MASK) != 0, alt = (e->state & GDK_MOD1_MASK) != 0;
	int vk = winKey(e->keyval);
	if (e->type == GDK_KEY_PRESS) {
		// Lite Go's own shortcuts first (Ctrl+T, Ctrl+L, F5, Alt+Left and so on)
		gunichar lc = gdk_keyval_to_unicode(gdk_keyval_to_lower(e->keyval));
		int special = vk == 0x25 || vk == 0x27 || vk == 0x74 || vk == 0x75 || vk == 0x7A || vk == 0x09 || vk == 0x21 || vk == 0x22 || vk == 0xA6 ||
		              vk == 0xA7;
		if ((ctrl || alt || special) && lgxGoKey(v->id, (int)lc, special ? vk : 0, ctrl, shift, alt)) {
			RELEASE(h);
			return TRUE;
		}
	}
	cef_key_event_t k = {0};
	k.size = sizeof k;
	k.modifiers = modsOf(e->state);
	k.windows_key_code = vk;
	k.native_key_code = e->hardware_keycode;
	gunichar ch = gdk_keyval_to_unicode(e->keyval);
	if (e->type == GDK_KEY_PRESS) {
		k.type = KEYEVENT_RAWKEYDOWN;
		h->send_key_event(h, &k);
		// typed text goes through the input method (dead keys: ´ then e is é)
		if (!ctrl && !alt && v->im && gtk_im_context_filter_keypress(v->im, e)) {
			RELEASE(h);
			return TRUE;
		}
		if (ch && !(ctrl && !alt)) {
			k.type = KEYEVENT_CHAR;
			if (vk == 0x0D) ch = '\r';
			k.windows_key_code = (int)ch;
			k.character = (char16_t)ch;
			k.unmodified_character = (char16_t)ch;
			h->send_key_event(h, &k);
		} else if (vk == 0x0D || vk == 0x08 || vk == 0x09 || vk == 0x1B) {
			k.type = KEYEVENT_CHAR;
			k.character = k.unmodified_character = (char16_t)(vk == 0x0D ? '\r' : vk);
			h->send_key_event(h, &k);
		}
	} else {
		if (v->im) gtk_im_context_filter_keypress(v->im, e);
		k.type = KEYEVENT_KEYUP;
		h->send_key_event(h, &k);
	}
	RELEASE(h);
	return TRUE;
}

static gboolean onFocusIn(GtkWidget *w, GdkEvent *e, LV *v) {
	cef_browser_host_t *h = hostOf(v);
	if (h) {
		h->set_focus(h, 1);
		RELEASE(h);
	}
	if (v->im) gtk_im_context_focus_in(v->im);
	lgxGoFocus(v->id);
	return FALSE;
}

static gboolean onFocusOut(GtkWidget *w, GdkEvent *e, LV *v) {
	cef_browser_host_t *h = hostOf(v);
	if (h) {
		h->set_focus(h, 0);
		RELEASE(h);
	}
	if (v->im) gtk_im_context_focus_out(v->im);
	return FALSE;
}

static gboolean onRealize(GtkWidget *w, LV *v) {
	if (v->im) gtk_im_context_set_client_window(v->im, gtk_widget_get_window(w));
	return FALSE;
}

static void makeArea(LV *v) {
	if (v->area || !host) return;
	v->area = gtk_drawing_area_new();
	gtk_widget_set_can_focus(v->area, TRUE);
	gtk_widget_add_events(v->area, GDK_POINTER_MOTION_MASK | GDK_BUTTON_PRESS_MASK | GDK_BUTTON_RELEASE_MASK | GDK_SCROLL_MASK | GDK_SMOOTH_SCROLL_MASK |
	                                   GDK_LEAVE_NOTIFY_MASK | GDK_KEY_PRESS_MASK | GDK_KEY_RELEASE_MASK | GDK_FOCUS_CHANGE_MASK);
	g_signal_connect(v->area, "draw", G_CALLBACK(onDraw), v);
	g_signal_connect(v->area, "button-press-event", G_CALLBACK(onButton), v);
	g_signal_connect(v->area, "button-release-event", G_CALLBACK(onButton), v);
	g_signal_connect(v->area, "motion-notify-event", G_CALLBACK(onMotion), v);
	g_signal_connect(v->area, "leave-notify-event", G_CALLBACK(onLeave), v);
	g_signal_connect(v->area, "scroll-event", G_CALLBACK(onScroll), v);
	g_signal_connect(v->area, "key-press-event", G_CALLBACK(onKey), v);
	g_signal_connect(v->area, "key-release-event", G_CALLBACK(onKey), v);
	g_signal_connect(v->area, "focus-in-event", G_CALLBACK(onFocusIn), v);
	g_signal_connect(v->area, "focus-out-event", G_CALLBACK(onFocusOut), v);
	g_signal_connect(v->area, "realize", G_CALLBACK(onRealize), v);
	v->im = gtk_im_context_simple_new();
	g_signal_connect(v->im, "commit", G_CALLBACK(onCommit), v);
	gtk_widget_set_no_show_all(v->area, TRUE);
	gtk_layout_put(host, v->area, 0, 0);
	gtk_widget_set_size_request(v->area, 1, 1);
	gtk_widget_realize(v->area);
}

// ---- the page's events ----

static void CEF_CALLBACK onAddress(cef_display_handler_t *self, cef_browser_t *b, cef_frame_t *f, const cef_string_t *url) {
	int main = f && f->is_main(f);
	RELEASE(f);
	LV *v = of(b);
	if (!v || !main) return;
	char *u = getStr(url);
	g_free(v->pageURL);
	v->pageURL = g_strdup(u);
	lgxGoURL(v->id, u);
	g_free(u);
}

static void CEF_CALLBACK onTitle(cef_display_handler_t *self, cef_browser_t *b, const cef_string_t *title) {
	LV *v = of(b);
	if (!v) return;
	char *t = getStr(title);
	lgxGoTitle(v->id, t);
	g_free(t);
}

static void CEF_CALLBACK onFullscreen(cef_display_handler_t *self, cef_browser_t *b, int on) {
	LV *v = of(b);
	if (v) lgxGoFullscreen(v->id, on);
}

// Run's results come back as a console message only this file writes.
#define RESULT_MARK "\x01lgx-result:"

static int CEF_CALLBACK onConsole(cef_display_handler_t *self, cef_browser_t *b, cef_log_severity_t level, const cef_string_t *msg,
                                  const cef_string_t *src, int line) {
	RELEASE(b);
	char *m = getStr(msg);
	int ours = 0;
	if (g_str_has_prefix(m, RESULT_MARK)) {
		ours = 1;
		char *rest = m + strlen(RESULT_MARK);
		char *colon = strchr(rest, ':');
		if (colon) {
			*colon = 0;
			uintptr_t cb = (uintptr_t)g_ascii_strtoull(rest, NULL, 10);
			if (cb) lgxGoResult(cb, colon + 1);
		}
	}
	g_free(m);
	return ours;
}

static int CEF_CALLBACK onCursor(cef_display_handler_t *self, cef_browser_t *b, cef_cursor_handle_t c, cef_cursor_type_t type, const cef_cursor_info_t *info) {
	LV *v = of(b);
	if (!v || !v->area) return 1;
	GdkWindow *win = gtk_widget_get_window(v->area);
	if (!win) return 1;
	const char *name = "default";
	switch (type) {
	case CT_HAND: name = "pointer"; break;
	case CT_IBEAM: name = "text"; break;
	case CT_WAIT: name = "wait"; break;
	case CT_PROGRESS: name = "progress"; break;
	case CT_CROSS: name = "crosshair"; break;
	case CT_HELP: name = "help"; break;
	case CT_MOVE: name = "move"; break;
	case CT_COLUMNRESIZE: name = "col-resize"; break;
	case CT_ROWRESIZE: name = "row-resize"; break;
	case CT_EASTWESTRESIZE: case CT_EASTRESIZE: case CT_WESTRESIZE: name = "ew-resize"; break;
	case CT_NORTHSOUTHRESIZE: case CT_NORTHRESIZE: case CT_SOUTHRESIZE: name = "ns-resize"; break;
	case CT_NOTALLOWED: name = "not-allowed"; break;
	case CT_GRAB: name = "grab"; break;
	case CT_GRABBING: name = "grabbing"; break;
	case CT_NONE: name = "none"; break;
	default: break;
	}
	GdkCursor *cur = gdk_cursor_new_from_name(gdk_window_get_display(win), name);
	gdk_window_set_cursor(win, cur);
	if (cur) g_object_unref(cur);
	return 1;
}

static cef_display_handler_t displayH;

static void CEF_CALLBACK onLoadingState(cef_load_handler_t *self, cef_browser_t *b, int loading, int back, int fwd) {
	LV *v = of(b);
	if (v) lgxGoLoading(v->id, loading, back, fwd);
}

// The page's scripts (the shield's helpers, Light YouTube) run as each
// document starts.
static void CEF_CALLBACK onLoadStart(cef_load_handler_t *self, cef_browser_t *b, cef_frame_t *f, cef_transition_type_t t) {
	LV *v = of(b);
	if (v && f) {
		for (GSList *l = v->scripts; l; l = l->next) {
			cef_string_t code = {0}, url = {0};
			setStr(&code, l->data);
			f->execute_java_script(f, &code, &url, 0);
			cef_string_clear(&code);
		}
	}
	RELEASE(f);
}

static cef_load_handler_t loadH;

// ---- browsers come and go ----

static void applyState(LV *v) {
	cef_browser_host_t *h = hostOf(v);
	if (!h) return;
	v->sf = scaleOf();
	h->notify_screen_info_changed(h);
	h->was_resized(h);
	h->was_hidden(h, !v->shown);
	if (v->muted) h->set_audio_muted(h, 1);
	if (v->zoom != 1) h->set_zoom_level(h, log(v->zoom) / log(1.2));
	RELEASE(h);
}

static void CEF_CALLBACK onAfterCreated(cef_life_span_handler_t *self, cef_browser_t *b) {
	// browsers are made in the order they were asked for
	LV *v = g_queue_pop_head(&pending);
	if (!v) {
		RELEASE(b);
		return;
	}
	if (v->closing) {
		cef_browser_host_t *h = b->get_host(b);
		h->close_browser(h, 1);
		RELEASE(h);
	}
	v->browser = b; // keeps the reference
	v->bid = b->get_identifier(b);
	g_mutex_lock(&lock);
	g_hash_table_insert(byBrowser, GINT_TO_POINTER(v->bid), v);
	g_mutex_unlock(&lock);
	applyState(v);
	uintptr_t cb = v->createdCB;
	v->createdCB = 0;
	if (cb) lgxGoCreated(cb, 1);
}

static int CEF_CALLBACK doClose(cef_life_span_handler_t *self, cef_browser_t *b) {
	RELEASE(b);
	return 0;
}

static void CEF_CALLBACK onBeforeClose(cef_life_span_handler_t *self, cef_browser_t *b) {
	int bid = b->get_identifier(b);
	RELEASE(b);
	g_mutex_lock(&lock);
	LV *v = g_hash_table_lookup(byBrowser, GINT_TO_POINTER(bid));
	g_hash_table_remove(byBrowser, GINT_TO_POINTER(bid));
	if (v) g_hash_table_remove(views, (gpointer)v->id);
	g_mutex_unlock(&lock);
	if (!v) return;
	if (v->browser) RELEASE(v->browser);
	if (v->area) gtk_widget_destroy(v->area);
	if (v->im) g_object_unref(v->im);
	if (v->page) cairo_surface_destroy(v->page);
	if (v->popup) cairo_surface_destroy(v->popup);
	g_slist_free_full(v->scripts, g_free);
	g_free(v->profile);
	g_free(v->startURL);
	g_free(v->pageURL);
	g_free(v);
}

// A link or a script asks for a new window: Lite Go opens a tab (or not),
// and that tab's page loads the address.
static int CEF_CALLBACK onBeforePopup(cef_life_span_handler_t *self, cef_browser_t *b, cef_frame_t *f, int popupID, const cef_string_t *url,
                                      const cef_string_t *name, cef_window_open_disposition_t disp, int gesture, const cef_popup_features_t *feat,
                                      cef_window_info_t *wi, cef_client_t **client, cef_browser_settings_t *settings, cef_dictionary_value_t **extra,
                                      int *noJS) {
	RELEASE(f);
	LV *v = of(b);
	if (!v) return 1;
	char *u = getStr(url);
	uintptr_t nid = lgxGoPopup(v->id, u);
	if (nid) {
		LV *n = lv(nid, 1);
		g_free(n->startURL);
		n->startURL = g_strdup(u);
		n->sandbox = v->sandbox;
		if (!n->profile) n->profile = g_strdup(v->profile ? v->profile : "");
		n->priv = v->priv;
	}
	g_free(u);
	return 1; // never CEF's own window
}

static cef_life_span_handler_t lifeH;

// ---- navigation and requests ----

static int CEF_CALLBACK onBeforeBrowse(cef_request_handler_t *self, cef_browser_t *b, cef_frame_t *f, cef_request_t *r, int gesture, int redirect) {
	int main = f && f->is_main(f);
	RELEASE(f);
	LV *v = of(b);
	char *u = takeStr(r->get_url(r));
	RELEASE(r);
	if (!v || !main) {
		g_free(u);
		return 0;
	}
	char *to = lgxGoDecide(v->id, u, gesture && !redirect);
	g_free(u);
	if (!to) return 0;
	if (strcmp(to, "-") != 0 && v->browser) {
		cef_frame_t *mf = v->browser->get_main_frame(v->browser);
		if (mf) {
			cef_string_t s = {0};
			setStr(&s, to);
			mf->load_url(mf, &s);
			cef_string_clear(&s);
			RELEASE(mf);
		}
	}
	free(to);
	return 1;
}

static void CEF_CALLBACK onTerminated(cef_request_handler_t *self, cef_browser_t *b, cef_termination_status_t st, int code, const cef_string_t *err) {
	LV *v = of(b);
	if (v) lgxGoCrashed(v->id);
}

typedef struct {
	uintptr_t id;
	char *url;
} Blocked;

static gboolean reportBlocked(gpointer d) {
	Blocked *x = d;
	if (lv(x->id, 0)) lgxGoBlocked(x->id, x->url);
	g_free(x->url);
	g_free(x);
	return G_SOURCE_REMOVE;
}

static const char *kindOf(cef_resource_type_t t) {
	switch (t) {
	case RT_SCRIPT: case RT_WORKER: case RT_SHARED_WORKER: case RT_SERVICE_WORKER: return "script";
	case RT_IMAGE: case RT_FAVICON: return "image";
	case RT_MEDIA: return "media";
	case RT_XHR: return "xmlhttprequest";
	case RT_PING: return "ping";
	default: return "other";
	}
}

// The shield, asked for each request (on CEF's IO thread).
static cef_return_value_t CEF_CALLBACK onBeforeResource(cef_resource_request_handler_t *self, cef_browser_t *b, cef_frame_t *f, cef_request_t *r,
                                                        cef_callback_t *cb) {
	RELEASE(f);
	RELEASE(cb);
	cef_resource_type_t t = r->get_resource_type(r);
	if (t == RT_MAIN_FRAME || !b) {
		RELEASE(b);
		RELEASE(r);
		return RV_CONTINUE;
	}
	int bid = b->get_identifier(b);
	RELEASE(b);
	g_mutex_lock(&lock);
	LV *v = g_hash_table_lookup(byBrowser, GINT_TO_POINTER(bid));
	uintptr_t id = v ? v->id : 0;
	char *page = v && v->pageURL ? g_strdup(v->pageURL) : g_strdup("");
	g_mutex_unlock(&lock);
	char *u = takeStr(r->get_url(r));
	RELEASE(r);
	int ok = !id || lgxGoAllow(id, u, page, (char *)kindOf(t));
	if (!ok) {
		Blocked *x = g_new0(Blocked, 1);
		x->id = id;
		x->url = g_strdup(u);
		g_main_context_invoke(NULL, reportBlocked, x);
	}
	g_free(u);
	g_free(page);
	return ok ? RV_CONTINUE : RV_CANCEL;
}

static cef_resource_request_handler_t resH;

static cef_resource_request_handler_t *CEF_CALLBACK getResH(cef_request_handler_t *self, cef_browser_t *b, cef_frame_t *f, cef_request_t *r, int nav,
                                                          int dl, const cef_string_t *init, int *noDefault) {
	RELEASE(b);
	RELEASE(f);
	RELEASE(r);
	return &resH;
}

static cef_request_handler_t requestH;

// ---- downloads ----

static int CEF_CALLBACK canDownload(cef_download_handler_t *self, cef_browser_t *b, const cef_string_t *url, const cef_string_t *method) {
	LV *v = of(b);
	return !(v && v->sandbox); // nothing from a sandbox reaches the disk
}

static char *freePath(const char *suggested) {
	const char *dir = g_get_user_special_dir(G_USER_DIRECTORY_DOWNLOAD);
	char *home = NULL;
	if (!dir) dir = home = g_build_filename(g_get_home_dir(), "Downloads", NULL);
	g_mkdir_with_parents(dir, 0755);
	char *name = g_path_get_basename(suggested && *suggested ? suggested : "download");
	char *path = g_build_filename(dir, name, NULL);
	for (int n = 1; g_file_test(path, G_FILE_TEST_EXISTS) && n < 1000; n++) {
		char *dot = strrchr(name, '.');
		char *stem = dot && dot != name ? g_strndup(name, dot - name) : g_strdup(name);
		char *next = g_strdup_printf("%s (%d)%s", stem, n + 1, dot && dot != name ? dot : "");
		g_free(path);
		path = g_build_filename(dir, next, NULL);
		g_free(stem);
		g_free(next);
	}
	g_free(name);
	g_free(home);
	return path;
}

static int CEF_CALLBACK onBeforeDownload(cef_download_handler_t *self, cef_browser_t *b, cef_download_item_t *item, const cef_string_t *suggested,
                                         cef_before_download_callback_t *cb) {
	RELEASE(b);
	RELEASE(item);
	char *s = getStr(suggested);
	char *path = freePath(s);
	cef_string_t p = {0};
	setStr(&p, path);
	cb->cont(cb, &p, 0);
	cef_string_clear(&p);
	RELEASE(cb);
	g_free(path);
	g_free(s);
	return 1;
}

static void CEF_CALLBACK onDownloadUpdated(cef_download_handler_t *self, cef_browser_t *b, cef_download_item_t *item, cef_download_item_callback_t *cb) {
	LV *v = of(b);
	uint32_t did = item->get_id(item);
	int state = DL_ACTIVE;
	if (item->is_complete(item)) state = DL_DONE;
	else if (item->is_canceled(item)) state = DL_CANCELED;
	else if (item->is_interrupted(item)) state = DL_FAILED;
	char *u = takeStr(item->get_url(item));
	char *path = takeStr(item->get_full_path(item));
	long long total = item->get_total_bytes(item), got = item->get_received_bytes(item);
	if (state == DL_ACTIVE) {
		cb->base.add_ref(&cb->base);
		cef_download_item_callback_t *old = g_hash_table_lookup(downloads, GUINT_TO_POINTER(did));
		g_hash_table_insert(downloads, GUINT_TO_POINTER(did), cb);
		RELEASE(old);
	} else {
		cef_download_item_callback_t *old = g_hash_table_lookup(downloads, GUINT_TO_POINTER(did));
		g_hash_table_remove(downloads, GUINT_TO_POINTER(did));
		RELEASE(old);
	}
	if (*path || state != DL_ACTIVE) lgxGoDownload(did, v ? v->id : 0, state, u, path, total > 0 ? total : -1, got);
	g_free(u);
	g_free(path);
	RELEASE(item);
	RELEASE(cb);
}

static cef_download_handler_t downloadH;

// ---- keys the page does not see first ----

static cef_keyboard_handler_t keyH;

// ---- permissions: a sandbox gets none; others are asked as usual ----

static int CEF_CALLBACK onPermissionPrompt(cef_permission_handler_t *self, cef_browser_t *b, uint64_t id, const cef_string_t *origin, uint32_t perms,
                                           cef_permission_prompt_callback_t *cb) {
	LV *v = of(b);
	int deny = v && v->sandbox;
	if (deny) cb->cont(cb, CEF_PERMISSION_RESULT_DENY);
	RELEASE(cb);
	return deny;
}

static cef_permission_handler_t permH;

// ---- the client: one for every page ----

static cef_client_t client;
static cef_render_handler_t *CEF_CALLBACK getRender(cef_client_t *s) { return &renderH; }
static cef_display_handler_t *CEF_CALLBACK getDisplay(cef_client_t *s) { return &displayH; }
static cef_load_handler_t *CEF_CALLBACK getLoad(cef_client_t *s) { return &loadH; }
static cef_life_span_handler_t *CEF_CALLBACK getLife(cef_client_t *s) { return &lifeH; }
static cef_request_handler_t *CEF_CALLBACK getRequest(cef_client_t *s) { return &requestH; }
static cef_download_handler_t *CEF_CALLBACK getDownload(cef_client_t *s) { return &downloadH; }
static cef_permission_handler_t *CEF_CALLBACK getPerm(cef_client_t *s) { return &permH; }

static void initHandlers(void) {
	STATIC_BASE(app);
	app.on_before_command_line_processing = onCommandLine;
	app.get_browser_process_handler = getBPH;
	STATIC_BASE(bph);
	bph.on_schedule_message_pump_work = onSchedulePump;

	STATIC_BASE(renderH);
	renderH.get_view_rect = getViewRect;
	renderH.get_screen_info = getScreenInfo;
	renderH.get_screen_point = getScreenPoint;
	renderH.on_paint = onPaint;
	renderH.on_popup_show = onPopupShow;
	renderH.on_popup_size = onPopupSize;

	STATIC_BASE(displayH);
	displayH.on_address_change = onAddress;
	displayH.on_title_change = onTitle;
	displayH.on_fullscreen_mode_change = onFullscreen;
	displayH.on_console_message = onConsole;
	displayH.on_cursor_change = onCursor;

	STATIC_BASE(loadH);
	loadH.on_loading_state_change = onLoadingState;
	loadH.on_load_start = onLoadStart;

	STATIC_BASE(lifeH);
	lifeH.on_before_popup = onBeforePopup;
	lifeH.on_after_created = onAfterCreated;
	lifeH.do_close = doClose;
	lifeH.on_before_close = onBeforeClose;

	STATIC_BASE(requestH);
	requestH.on_before_browse = onBeforeBrowse;
	requestH.get_resource_request_handler = getResH;
	requestH.on_render_process_terminated = onTerminated;
	STATIC_BASE(resH);
	resH.on_before_resource_load = onBeforeResource;

	STATIC_BASE(downloadH);
	downloadH.can_download = canDownload;
	downloadH.on_before_download = onBeforeDownload;
	downloadH.on_download_updated = onDownloadUpdated;

	STATIC_BASE(keyH);
	STATIC_BASE(permH);
	permH.on_show_permission_prompt = onPermissionPrompt;

	STATIC_BASE(client);
	client.get_render_handler = getRender;
	client.get_display_handler = getDisplay;
	client.get_load_handler = getLoad;
	client.get_life_span_handler = getLife;
	client.get_request_handler = getRequest;
	client.get_download_handler = getDownload;
	client.get_permission_handler = getPerm;
}

// ---- containers: each profile is a request context with its own storage ----

static cef_request_context_t *contextFor(const char *profile, int priv) {
	char *key = g_strdup_printf("%s:%s", priv ? "private" : "disk", profile ? profile : "");
	cef_request_context_t *c = g_hash_table_lookup(contexts, key);
	if (c) {
		g_free(key);
		return c;
	}
	cef_request_context_settings_t s = {0};
	s.size = sizeof s;
	if (!priv) {
		char *path = g_build_filename(dataDir, "cef", profile && *profile ? profile : "default", NULL);
		setStr(&s.cache_path, path);
		g_free(path);
		s.persist_session_cookies = 1;
	}
	c = cef_request_context_create_context(&s, NULL);
	cef_string_clear(&s.cache_path);
	g_hash_table_insert(contexts, key, c);
	return c;
}

static void createBrowser(LV *v) {
	makeArea(v);
	cef_window_info_t wi = {0};
	wi.size = sizeof wi;
	wi.windowless_rendering_enabled = 1;
	wi.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
	cef_browser_settings_t bs = {0};
	bs.size = sizeof bs;
	bs.windowless_frame_rate = 60;
	bs.background_color = 0xFFFFFFFF;
	cef_string_t url = {0};
	setStr(&url, v->startURL ? v->startURL : "about:blank");
	cef_request_context_t *ctx = contextFor(v->profile, v->priv);
	ctx->base.base.add_ref(&ctx->base.base); // create_browser takes one
	if (cef_browser_host_create_browser(&wi, &client, &url, &bs, NULL, ctx)) {
		g_queue_push_tail(&pending, v);
	} else {
		uintptr_t cb = v->createdCB;
		v->createdCB = 0;
		if (cb) lgxGoCreated(cb, 0);
	}
	cef_string_clear(&url);
	g_free(v->startURL);
	v->startURL = NULL;
}

// ---- operations from Go ----

typedef struct {
	int op;
	uintptr_t id, cb;
	int a, b, c, d;
	char *s;
} Op;

static void navigate(LV *v, const char *u) {
	if (!v->browser) {
		g_free(v->startURL);
		v->startURL = g_strdup(u);
		return;
	}
	cef_frame_t *f = v->browser->get_main_frame(v->browser);
	if (!f) return;
	cef_string_t s = {0};
	setStr(&s, u);
	f->load_url(f, &s);
	cef_string_clear(&s);
	RELEASE(f);
}

static void evalJS(LV *v, const char *js, uintptr_t cb) {
	if (!v || !v->browser) {
		if (cb) lgxGoResult(cb, "null");
		return;
	}
	cef_frame_t *f = v->browser->get_main_frame(v->browser);
	if (!f) {
		if (cb) lgxGoResult(cb, "null");
		return;
	}
	char *code;
	if (cb) {
		// the result comes back as a marked console message (onConsole)
		code = g_strdup_printf("(async () => { let r = 'null'; try { const v = await (0, eval)(%s); r = JSON.stringify(v === undefined ? null : v); "
		                       "if (r === undefined) r = 'null'; } catch (e) {} console.log('\\x01lgx-result:%" G_GUINT64_FORMAT ":' + r); })();",
		                       js, (guint64)cb);
		// js is passed as a string literal (see below)
	} else {
		code = g_strdup(js);
	}
	cef_string_t s = {0}, url = {0};
	setStr(&s, code);
	f->execute_java_script(f, &s, &url, 0);
	cef_string_clear(&s);
	g_free(code);
	RELEASE(f);
}

// jsString quotes s as a JavaScript string literal.
static char *jsString(const char *s) {
	GString *o = g_string_new("\"");
	for (const char *p = s; *p; p++) {
		switch (*p) {
		case '"': g_string_append(o, "\\\""); break;
		case '\\': g_string_append(o, "\\\\"); break;
		case '\n': g_string_append(o, "\\n"); break;
		case '\r': g_string_append(o, "\\r"); break;
		case '\t': g_string_append(o, "\\t"); break;
		default:
			if ((unsigned char)*p < 0x20) g_string_append_printf(o, "\\u%04x", *p);
			else g_string_append_c(o, *p);
		}
	}
	g_string_append_c(o, '"');
	return g_string_free(o, FALSE);
}

static gboolean runOp(gpointer data) {
	Op *op = data;
	LV *v = op->id && op->op != OP_DLCANCEL ? lv(op->id, op->op == OP_SCRIPT || op->op == OP_PROFILE || op->op == OP_NEW) : NULL;
	cef_browser_host_t *h = v ? hostOf(v) : NULL;
	switch (op->op) {
	case OP_SCRIPT:
		v->scripts = g_slist_append(v->scripts, g_strdup(op->s));
		break;
	case OP_PROFILE:
		g_free(v->profile);
		v->profile = g_strdup(op->s ? op->s : "");
		v->priv = op->a;
		v->sandbox = op->b;
		break;
	case OP_DLCANCEL: {
		cef_download_item_callback_t *cb = g_hash_table_lookup(downloads, GUINT_TO_POINTER((guint)op->id));
		if (cb) cb->cancel(cb);
		break;
	}
	case OP_NEW:
		if (!started) {
			lgxGoCreated(op->cb, 0);
			break;
		}
		if (v->browser) {
			lgxGoCreated(op->cb, 1);
			break;
		}
		v->createdCB = op->cb;
		createBrowser(v);
		break;
	case OP_NAV:
		if (v) navigate(v, op->s);
		break;
	case OP_BOUNDS:
		if (v) {
			int sf = scaleOf();
			int w = op->c / sf, hh = op->d / sf;
			if (w < 1) w = 1;
			if (hh < 1) hh = 1;
			makeArea(v);
			gtk_layout_move(host, v->area, op->a / sf, op->b / sf);
			gtk_widget_set_size_request(v->area, w, hh);
			if (h && sf != v->sf) {
				// the window moved to a screen with another scale (or the first
				// size arrived before the window knew its scale)
				v->sf = sf;
				h->notify_screen_info_changed(h);
			}
			if (w != v->w || hh != v->h) {
				v->w = w, v->h = hh;
				if (h) h->was_resized(h);
			}
		}
		break;
	case OP_SHOW:
		if (v) {
			v->shown = op->a;
			makeArea(v);
			if (op->a) gtk_widget_show(v->area);
			else gtk_widget_hide(v->area);
			if (h) h->was_hidden(h, !op->a);
		}
		break;
	case OP_EVAL: {
		uintptr_t cb = op->cb;
		op->cb = 0;
		if (cb) {
			char *lit = jsString(op->s ? op->s : "");
			evalJS(v, lit, cb);
			g_free(lit);
		} else {
			evalJS(v, op->s ? op->s : "", 0);
		}
		break;
	}
	default:
		if (!v || !v->browser) break;
		switch (op->op) {
		case OP_BACK: v->browser->go_back(v->browser); break;
		case OP_FWD: v->browser->go_forward(v->browser); break;
		case OP_RELOAD: v->browser->reload(v->browser); break;
		case OP_STOP: v->browser->stop_load(v->browser); break;
		case OP_FOCUS:
			if (v->area) gtk_widget_grab_focus(v->area);
			if (h) h->set_focus(h, 1);
			break;
		case OP_MUTE:
			v->muted = op->a;
			if (h) h->set_audio_muted(h, op->a);
			break;
		case OP_ZOOM:
			v->zoom = op->a / 100.0;
			if (h && v->zoom > 0) h->set_zoom_level(h, log(v->zoom) / log(1.2));
			break;
		case OP_CLOSE:
			v->closing = 1;
			if (v->area) gtk_widget_hide(v->area);
			if (h) h->close_browser(h, 1);
			break;
		}
	}
	RELEASE(h);
	if (op->op == OP_EVAL && op->cb) lgxGoResult(op->cb, "null");
	g_free(op->s);
	g_free(op);
	return G_SOURCE_REMOVE;
}

void lgxCall(int op, uintptr_t id, int a, int b, int c, int d, const char *s, uintptr_t cb) {
	Op *o = g_new0(Op, 1);
	o->op = op, o->id = id, o->a = a, o->b = b, o->c = c, o->d = d, o->cb = cb;
	o->s = s ? g_strdup(s) : NULL;
	g_main_context_invoke(NULL, runOp, o);
}

// With LITEGO_SHOT=<prefix> set (the tests), the page on screen is written
// to <prefix>-1.png, -2.png and so on, every five seconds.
static gboolean shotTick(gpointer d) {
	static int n;
	const char *pre = g_getenv("LITEGO_SHOT");
	if (!pre || n >= 3) return G_SOURCE_REMOVE;
	GHashTableIter it;
	gpointer k, val;
	g_hash_table_iter_init(&it, views);
	while (g_hash_table_iter_next(&it, &k, &val)) {
		LV *v = val;
		if (v->shown && v->page) {
			char *path = g_strdup_printf("%s-%d.png", pre, ++n);
			// at half size, so the tests can print it into their log
			int w = cairo_image_surface_get_width(v->page) / 2, h = cairo_image_surface_get_height(v->page) / 2;
			cairo_surface_t *small = cairo_image_surface_create(CAIRO_FORMAT_RGB24, w, h);
			cairo_t *cr = cairo_create(small);
			double sx, sy;
			cairo_surface_get_device_scale(v->page, &sx, &sy);
			cairo_scale(cr, sx / 2, sy / 2);
			cairo_set_source_surface(cr, v->page, 0, 0);
			cairo_paint(cr);
			cairo_destroy(cr);
			cairo_surface_write_to_png(small, path);
			cairo_surface_destroy(small);
			g_printerr("Lite Go: page written to %s (%dx%d)\n", path, cairo_image_surface_get_width(v->page), cairo_image_surface_get_height(v->page));
			g_free(path);
			break;
		}
	}
	return G_SOURCE_CONTINUE;
}

// ---- start ----

static char *exeDir(void) {
	char buf[4096];
	ssize_t n = readlink("/proc/self/exe", buf, sizeof buf - 1);
	if (n <= 0) return g_strdup(".");
	buf[n] = 0;
	return g_path_get_dirname(buf);
}

static void setup(const char *dir) {
	if (views) return;
	dataDir = g_strdup(dir);
	views = g_hash_table_new(g_direct_hash, g_direct_equal);
	byBrowser = g_hash_table_new(g_direct_hash, g_direct_equal);
	contexts = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
	downloads = g_hash_table_new(g_direct_hash, g_direct_equal);
	initHandlers();
	cef_api_hash(CEF_API_VERSION, 0);

	char *bin = exeDir();
	char *helper = g_build_filename(bin, "lite-go-helper", NULL);
	char *root = g_build_filename(dir, "cef", NULL);
	char *locales = g_build_filename(bin, "locales", NULL);
	g_mkdir_with_parents(root, 0700);

	cef_settings_t s = {0};
	s.size = sizeof s;
	noSandbox = sandboxMissing(bin);
	if (noSandbox) g_printerr("Lite Go: Chromium runs without its sandbox here (no setuid chrome-sandbox, no user namespaces)\n");
	s.no_sandbox = noSandbox;
	s.external_message_pump = 1;
	s.multi_threaded_message_loop = 0;
	s.windowless_rendering_enabled = 1;
	s.persist_session_cookies = 1;
	s.log_severity = g_getenv("LITEGO_CEF_VERBOSE") ? LOGSEVERITY_INFO : LOGSEVERITY_ERROR;
	s.background_color = 0xFFFFFFFF;
	setStr(&s.browser_subprocess_path, helper);
	setStr(&s.root_cache_path, root);
	setStr(&s.resources_dir_path, bin);
	setStr(&s.locales_dir_path, locales);
	const char *lang = g_getenv("LANG");
	if (lang && strlen(lang) >= 2 && strncmp(lang, "C", 1) != 0) {
		char *l = g_strndup(lang, strcspn(lang, "_.@"));
		setStr(&s.locale, l);
		g_free(l);
	}
	cef_main_args_t args = {0, NULL};
	started = cef_initialize(&args, &s, &app, NULL);
	if (!started) g_printerr("Lite Go: Chromium (CEF) could not start\n");
	// a steady beat as well, for work CEF does not schedule
	g_timeout_add(250, pumpTick, NULL); // CEF schedules its own work; this beat only catches what it did not
	if (g_getenv("LITEGO_SHOT")) g_timeout_add_seconds(5, shotTick, NULL);
	g_free(bin);
	g_free(helper);
	g_free(root);
	g_free(locales);
}

// lgxAttach starts the engine in Lite Go's GTK window (on GTK's thread).
void lgxAttach(uintptr_t layout, const char *dir) {
	host = GTK_LAYOUT((GtkWidget *)layout);
	g_object_add_weak_pointer(G_OBJECT(host), (gpointer *)&host);
	setup(dir);
}

// lgxMain is the Gio-window variant, which the Chromium engine does not use.
void lgxMain(unsigned long parent, const char *dir) {
	gtk_init(NULL, NULL);
	setup(dir);
	gtk_main();
}

char *lgxVersion(void) {
	char buf[64];
	snprintf(buf, sizeof buf, "Chromium %d.%d.%d.%d", CHROME_VERSION_MAJOR, CHROME_VERSION_MINOR, CHROME_VERSION_BUILD, CHROME_VERSION_PATCH);
	return strdup(buf);
}
