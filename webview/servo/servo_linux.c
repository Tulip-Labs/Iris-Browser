//go:build linux && webkit && servo

// Servo's pages in Iris's GTK window (see cef_linux.c for Chromium's): each
// page's frames become a texture the window's view draws over the interface,
// one page pixel on one screen pixel, and the pointer, the wheel and the keys
// of a Servo page go to it. Servo runs on GTK's thread.

#define _GNU_SOURCE
#include <dlfcn.h>
#include <gtk/gtk.h>
#include <math.h>
#include <stdint.h>
#include <string.h>

#include "irisservo.h"

extern void lsvGoEvent(uint64_t id, int kind, char *text, int a, int b);
extern int lsvGoAllow(uint64_t id, char *url, char *page, char *kind);
extern int lsvGoNavigate(uint64_t id, char *url);
extern void lsvGoResult(uint64_t token, char *json);
extern int lsvGoKey(uint64_t id, int vk, int ctrl, int shift, int alt);
extern void lsvGoFocus(uint64_t id);

typedef struct {
	uint64_t id;
	int px[4]; // where the page is in the window, in real pixels
	int shown;
	GdkTexture *tex;
	char *cursor;
} SV;

static GtkWidget *host;
static GHashTable *pages; // id -> SV*
static SV *focusPage, *hoverPage, *grabPage;
static double accX, accY; // the touchpad's moves not yet sent
static SV *accPage;

// ---- the scale (as in cmd/iris/gtk_linux.c) ----

static double (*p_surface_get_scale)(GdkSurface *);
static void (*p_append_scaled)(GtkSnapshot *, GdkTexture *, GskScalingFilter, const graphene_rect_t *);
static int (*p_scroll_unit)(GdkEvent *);

static int drawsFractional(void) {
	static int f = -1;
	if (f < 0) {
		const char *d = g_getenv("GDK_DEBUG");
		if (d && strstr(d, "gl-no-fractional")) f = 0;
		else if (d && strstr(d, "gl-fractional")) f = 1;
		else f = gtk_get_minor_version() >= 14;
	}
	return f;
}

static double scaleOf(void) {
	GtkNative *n = host ? gtk_widget_get_native(host) : NULL;
	GdkSurface *s = n ? gtk_native_get_surface(n) : NULL;
	if (!s) return host ? gtk_widget_get_scale_factor(host) : 1;
	double sc = p_surface_get_scale && drawsFractional() ? p_surface_get_scale(s) : gdk_surface_get_scale_factor(s);
	return sc > 0.25 ? sc : 1;
}

// lastScale is the scale the pages were last told (lsvBounds refreshes it
// when the window's changes, as lsvOpen does on open).
static double lastScale;

// ---- Servo's callbacks ----

static volatile int spinWanted;

static gboolean spinIdle(gpointer d) {
	__atomic_store_n(&spinWanted, 0, __ATOMIC_SEQ_CST);
	iris_servo_spin();
	return G_SOURCE_REMOVE;
}

// any thread
static void onWake(void) {
	if (__atomic_exchange_n(&spinWanted, 1, __ATOMIC_SEQ_CST) == 0) g_idle_add_full(G_PRIORITY_DEFAULT, spinIdle, NULL, NULL);
}

static void onEvent(uint64_t id, int kind, const char *text, int a, int b) {
	SV *v = pages ? g_hash_table_lookup(pages, &id) : NULL;
	if (kind == 7 && v) { // the cursor
		g_free(v->cursor);
		v->cursor = g_strdup(text);
		if (hoverPage == v && host) gtk_widget_set_cursor_from_name(host, strcmp(text, "default") == 0 ? NULL : text);
		return;
	}
	lsvGoEvent(id, kind, (char *)text, a, b);
}

static void onFrame(uint64_t id, const uint8_t *rgba, int w, int h) {
	SV *v = pages ? g_hash_table_lookup(pages, &id) : NULL;
	if (!v || w <= 0 || h <= 0) return;
	GBytes *bytes = g_bytes_new(rgba, (gsize)w * h * 4);
	GdkTexture *t = gdk_memory_texture_new(w, h, GDK_MEMORY_R8G8B8A8_PREMULTIPLIED, bytes, (gsize)w * 4);
	g_bytes_unref(bytes);
	if (v->tex) g_object_unref(v->tex);
	v->tex = t;
	if (v->shown && host) gtk_widget_queue_draw(host);
}

static int onAllow(uint64_t id, const char *url, const char *page, const char *kind) {
	return lsvGoAllow(id, (char *)url, (char *)page, (char *)kind);
}

static int onNavigate(uint64_t id, const char *url) { return lsvGoNavigate(id, (char *)url); }

static void onResult(uint64_t token, const char *json) { lsvGoResult(token, (char *)json); }

// lsvStart starts Servo in the window's view (on GTK's thread); 1 when it ran.
int lsvStart(uintptr_t view) {
	host = GTK_WIDGET((gpointer)view);
	p_surface_get_scale = dlsym(RTLD_DEFAULT, "gdk_surface_get_scale");
	p_append_scaled = dlsym(RTLD_DEFAULT, "gtk_snapshot_append_scaled_texture");
	p_scroll_unit = dlsym(RTLD_DEFAULT, "gdk_scroll_event_get_unit");
	pages = g_hash_table_new(g_int64_hash, g_int64_equal);
	lastScale = scaleOf();
	return iris_servo_init(onWake, onEvent, onFrame, onAllow, onNavigate, onResult, (float)lastScale);
}

int lsvOpen(uint64_t id, const char *url) {
	SV *v = g_new0(SV, 1);
	v->id = id;
	g_hash_table_insert(pages, &v->id, v);
	lastScale = scaleOf();
	iris_servo_set_scale((float)lastScale);
	int ok = iris_servo_open(id, 640, 480, url);
	onWake();
	return ok;
}

static gboolean closeLater(gpointer d) {
	uint64_t id = (uint64_t)(uintptr_t)d;
	iris_servo_close(id);
	return G_SOURCE_REMOVE;
}

void lsvClose(uint64_t id) {
	SV *v = g_hash_table_lookup(pages, &id);
	if (!v) return;
	if (focusPage == v) focusPage = NULL;
	if (hoverPage == v) hoverPage = NULL;
	if (grabPage == v) grabPage = NULL;
	if (accPage == v) accPage = NULL;
	g_hash_table_remove(pages, &id);
	if (v->tex) g_object_unref(v->tex);
	g_free(v->cursor);
	g_free(v);
	if (host) gtk_widget_queue_draw(host);
	// Servo may be in the middle of telling this page something: it closes
	// once that is over
	g_idle_add(closeLater, (gpointer)(uintptr_t)id);
}

void lsvBounds(uint64_t id, int x, int y, int w, int h) {
	SV *v = g_hash_table_lookup(pages, &id);
	if (!v) return;
	v->px[0] = x, v->px[1] = y, v->px[2] = w, v->px[3] = h;
	// the window's scale can change after a page opened (the window moved
	// to another screen, or the compositor corrected its first guess): the
	// pages' scale follows it, as on open, instead of laying out at the
	// old one until the page is reopened
	double sc = scaleOf();
	if (fabs(sc - lastScale) > 0.001) {
		lastScale = sc;
		iris_servo_set_scale((float)sc);
	}
	iris_servo_resize(id, w, h);
	onWake();
	if (host) gtk_widget_queue_draw(host);
}

void lsvShow(uint64_t id, int on) {
	SV *v = g_hash_table_lookup(pages, &id);
	if (!v) return;
	v->shown = on;
	iris_servo_show(id, on);
	onWake();
	if (host) gtk_widget_queue_draw(host);
}

void lsvFocus(uint64_t id) {
	SV *v = g_hash_table_lookup(pages, &id);
	if (!v) return;
	if (focusPage && focusPage != v) iris_servo_focus(focusPage->id, 0);
	focusPage = v;
	iris_servo_focus(id, 1);
	onWake();
}

void lsvWake(void) { onWake(); }

// ---- drawing ----

static void appendTexture(GtkSnapshot *s, GdkTexture *t, const graphene_rect_t *r, int sharp) {
	if (p_append_scaled) p_append_scaled(s, t, sharp ? GSK_SCALING_FILTER_NEAREST : GSK_SCALING_FILTER_LINEAR, r);
	else gtk_snapshot_append_texture(s, t, r);
}

// lsvSnapshotPages draws the Servo pages on screen (the window's view calls
// it, its scale s).
void lsvSnapshotPages(GtkSnapshot *sn, double s) {
	if (!pages || s <= 0) return;
	GHashTableIter it;
	gpointer k, val;
	g_hash_table_iter_init(&it, pages);
	while (g_hash_table_iter_next(&it, &k, &val)) {
		SV *v = val;
		if (!v->shown || v->px[2] <= 0 || v->px[3] <= 0) continue;
		graphene_rect_t r = GRAPHENE_RECT_INIT(v->px[0] / s, v->px[1] / s, v->px[2] / s, v->px[3] / s);
		gtk_snapshot_push_clip(sn, &r);
		if (v->tex) {
			int tw = gdk_texture_get_width(v->tex), th = gdk_texture_get_height(v->tex);
			if (abs(tw - v->px[2]) <= 1 && abs(th - v->px[3]) <= 1) appendTexture(sn, v->tex, &GRAPHENE_RECT_INIT(r.origin.x, r.origin.y, tw / s, th / s), 1);
			else appendTexture(sn, v->tex, &r, 0);
		} else {
			GdkRGBA white = {1, 1, 1, 1};
			gtk_snapshot_append_color(sn, &white, &r);
		}
		gtk_snapshot_pop(sn);
	}
}

// ---- input ----

static SV *pageAt(double x, double y) {
	if (!pages) return NULL;
	double s = scaleOf(), px = x * s, py = y * s;
	GHashTableIter it;
	gpointer k, val;
	g_hash_table_iter_init(&it, pages);
	while (g_hash_table_iter_next(&it, &k, &val)) {
		SV *v = val;
		if (v->shown && px >= v->px[0] && py >= v->px[1] && px < v->px[0] + v->px[2] && py < v->px[1] + v->px[3]) return v;
	}
	return NULL;
}

void lsvUIFocus(void) {
	if (focusPage) iris_servo_focus(focusPage->id, 0);
	focusPage = NULL;
}

void lsvPagesLeave(void) {
	if (hoverPage && !grabPage) {
		hoverPage = NULL;
		if (host) gtk_widget_set_cursor(host, NULL);
	}
}

// lsvPagePointer takes a pointer event over a Servo page (x, y in the view's
// units); 1 when it was the page's.
int lsvPagePointer(GdkEvent *e, double x, double y) {
	if (!pages) return 0;
	SV *v = grabPage ? grabPage : pageAt(x, y);
	if (v != hoverPage) {
		hoverPage = v;
		if (host) gtk_widget_set_cursor_from_name(host, v && v->cursor && strcmp(v->cursor, "default") ? v->cursor : NULL);
	}
	if (!v) return 0;
	double s = scaleOf();
	float px = (float)(x * s - v->px[0]), py = (float)(y * s - v->px[1]);
	switch (gdk_event_get_event_type(e)) {
	case GDK_BUTTON_PRESS:
	case GDK_BUTTON_RELEASE: {
		int press = gdk_event_get_event_type(e) == GDK_BUTTON_PRESS;
		guint b = gdk_button_event_get_button(e);
		if (b == 8 || b == 9) {
			if (press) {
				if (b == 8) iris_servo_back(v->id);
				else iris_servo_forward(v->id);
			}
			break;
		}
		if (press) {
			lsvFocus(v->id);
			lsvGoFocus(v->id);
			grabPage = v;
		} else {
			grabPage = NULL;
		}
		iris_servo_mouse_button(v->id, px, py, (int)b, press);
		break;
	}
	case GDK_MOTION_NOTIFY:
		iris_servo_mouse_move(v->id, px, py);
		break;
	case GDK_SCROLL: {
		if (accPage != v) accPage = v, accX = accY = 0;
		double dx = 0, dy = 0;
		int pixels = 0;
		switch (gdk_scroll_event_get_direction(e)) {
		case GDK_SCROLL_UP: dy = -1; break;
		case GDK_SCROLL_DOWN: dy = 1; break;
		case GDK_SCROLL_LEFT: dx = -1; break;
		case GDK_SCROLL_RIGHT: dx = 1; break;
		case GDK_SCROLL_SMOOTH: {
			gdk_scroll_event_get_deltas(e, &dx, &dy);
			if (p_scroll_unit) pixels = p_scroll_unit(e) == 1;
			else {
				GdkDevice *d = gdk_event_get_device(e);
				GdkInputSource src = d ? gdk_device_get_source(d) : GDK_SOURCE_MOUSE;
				pixels = src == GDK_SOURCE_TOUCHPAD || src == GDK_SOURCE_TOUCHSCREEN || src == GDK_SOURCE_TRACKPOINT;
			}
			if (gdk_scroll_event_is_stop(e)) accX = accY = 0;
			break;
		}
		}
		if ((gdk_event_get_modifier_state(e) & GDK_SHIFT_MASK) && dx == 0) dx = dy, dy = 0;
		if (pixels) {
			// a touchpad's moves, often under a pixel each, add up
			accX += dx * s, accY += dy * s;
			double sx = trunc(accX), sy = trunc(accY);
			accX -= sx, accY -= sy;
			if (sx != 0 || sy != 0) iris_servo_wheel(v->id, px, py, sx, sy, 1);
		} else {
			iris_servo_wheel(v->id, px, py, dx, dy, 0);
		}
		break;
	}
	default:
		break;
	}
	onWake();
	return 1;
}

// the DOM key value of a GDK key
static const char *named(guint kv) {
	switch (kv) {
	case GDK_KEY_Return: case GDK_KEY_KP_Enter: return "Enter";
	case GDK_KEY_BackSpace: return "Backspace";
	case GDK_KEY_Tab: case GDK_KEY_ISO_Left_Tab: return "Tab";
	case GDK_KEY_Escape: return "Escape";
	case GDK_KEY_Delete: case GDK_KEY_KP_Delete: return "Delete";
	case GDK_KEY_Insert: return "Insert";
	case GDK_KEY_Left: case GDK_KEY_KP_Left: return "ArrowLeft";
	case GDK_KEY_Right: case GDK_KEY_KP_Right: return "ArrowRight";
	case GDK_KEY_Up: case GDK_KEY_KP_Up: return "ArrowUp";
	case GDK_KEY_Down: case GDK_KEY_KP_Down: return "ArrowDown";
	case GDK_KEY_Home: case GDK_KEY_KP_Home: return "Home";
	case GDK_KEY_End: case GDK_KEY_KP_End: return "End";
	case GDK_KEY_Page_Up: case GDK_KEY_KP_Page_Up: return "PageUp";
	case GDK_KEY_Page_Down: case GDK_KEY_KP_Page_Down: return "PageDown";
	case GDK_KEY_Shift_L: case GDK_KEY_Shift_R: return "Shift";
	case GDK_KEY_Control_L: case GDK_KEY_Control_R: return "Control";
	case GDK_KEY_Alt_L: case GDK_KEY_Alt_R: return "Alt";
	case GDK_KEY_Super_L: case GDK_KEY_Super_R: case GDK_KEY_Meta_L: case GDK_KEY_Meta_R: return "Meta";
	case GDK_KEY_Caps_Lock: return "CapsLock";
	}
	if (kv >= GDK_KEY_F1 && kv <= GDK_KEY_F12) {
		static char f[4];
		snprintf(f, sizeof f, "F%d", (int)(kv - GDK_KEY_F1 + 1));
		return f;
	}
	return NULL;
}

// the Windows key code the browser's shortcut table uses
static int vkOf(guint kv) {
	if (kv >= GDK_KEY_a && kv <= GDK_KEY_z) return 'A' + (int)(kv - GDK_KEY_a);
	if (kv >= GDK_KEY_A && kv <= GDK_KEY_Z) return 'A' + (int)(kv - GDK_KEY_A);
	if (kv >= GDK_KEY_0 && kv <= GDK_KEY_9) return '0' + (int)(kv - GDK_KEY_0);
	if (kv >= GDK_KEY_F1 && kv <= GDK_KEY_F12) return 0x70 + (int)(kv - GDK_KEY_F1);
	switch (kv) {
	case GDK_KEY_Tab: case GDK_KEY_ISO_Left_Tab: return 0x09;
	case GDK_KEY_Return: return 0x0D;
	case GDK_KEY_Escape: return 0x1B;
	case GDK_KEY_Left: return 0x25;
	case GDK_KEY_Up: return 0x26;
	case GDK_KEY_Right: return 0x27;
	case GDK_KEY_Down: return 0x28;
	case GDK_KEY_plus: case GDK_KEY_equal: return 0xBB;
	case GDK_KEY_minus: return 0xBD;
	case GDK_KEY_comma: return 0xBC;
	case GDK_KEY_BackSpace: return 0x08;
	}
	return 0;
}

// lsvPageKey gives a key to the focused Servo page; 1 when it took it.
int lsvPageKey(GdkEvent *e) {
	if (!focusPage) return 0;
	GdkEventType t = gdk_event_get_event_type(e);
	if (t != GDK_KEY_PRESS && t != GDK_KEY_RELEASE) return 0;
	guint kv = gdk_key_event_get_keyval(e);
	GdkModifierType m = gdk_event_get_modifier_state(e);
	int ctrl = (m & GDK_CONTROL_MASK) != 0, shift = (m & GDK_SHIFT_MASK) != 0, alt = (m & GDK_ALT_MASK) != 0;
	int press = t == GDK_KEY_PRESS;
	// the browser's shortcuts first (Ctrl+T, Ctrl+L, F5…)
	if (press) {
		int vk = vkOf(kv);
		if (vk && (ctrl || alt || (vk >= 0x70 && vk <= 0x7B) || vk == 0x1B) && lsvGoKey(focusPage->id, vk, ctrl, shift, alt)) return 1;
	}
	const char *key = named(kv);
	char ch[8] = {0};
	if (!key) {
		gunichar c = gdk_keyval_to_unicode(kv);
		if (!c) return 0;
		ch[g_unichar_to_utf8(c, ch)] = 0;
		key = ch;
	}
	int mods = shift | ctrl << 1 | alt << 2 | ((m & GDK_SUPER_MASK) ? 8 : 0);
	iris_servo_key(focusPage->id, key, "", press, mods, 0);
	onWake();
	return 1;
}

// ---- the memory check (lsvGoTick in servo.go) ----

extern void lsvGoTick(void);

static gboolean tick(gpointer d) {
	lsvGoTick();
	return G_SOURCE_CONTINUE;
}

void lsvTicks(void) {
	static int on;
	if (!on) on = 1, g_timeout_add_seconds(10, tick, NULL);
}
