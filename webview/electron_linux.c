//go:build linux && webkit

// The Linux side of Iris's web engine on Electron: the pages' pictures and
// the input that goes to them.
//
// Electron runs in a helper process (webview/electron/helper), started by Go
// (engine_electron.go) when the first page opens, and draws each page off
// screen. Go receives each page's frames from it and hands them here, where
// they become textures that Iris's window draws over the interface
// (lgxSnapshotPages), one page pixel on one screen pixel. The pointer, the
// wheel and the keys over a page go back to Go (elxGo*), which sends them to
// Electron.
//
// Everything here runs on GTK's thread; Go's calls from other threads are
// moved there (g_main_context_invoke).

#define _GNU_SOURCE // RTLD_DEFAULT
#include <dlfcn.h>
#include <gtk/gtk.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// Go (engine_electron.go)
extern void elxGoMouse(uintptr_t id, int kind, double x, double y, int button, int clicks, unsigned int mods);
extern void elxGoWheel(uintptr_t id, double x, double y, double dx, double dy, int precise, unsigned int mods);
extern void elxGoKeyEv(uintptr_t id, int down, char *code, unsigned int mods);
extern void elxGoChar(uintptr_t id, char *text, unsigned int mods);
extern void elxGoNav(uintptr_t id, int fwd);
extern int lgxGoKey(uintptr_t id, int ch, int vk, int ctrl, int shift, int alt);
extern void lgxGoFocus(uintptr_t id);
extern void elxGoRun(uintptr_t h);

// modifiers as Go reads them
enum { M_SHIFT = 1, M_CTRL = 2, M_ALT = 4, M_META = 8, M_LEFT = 16, M_MIDDLE = 32, M_RIGHT = 64, M_CAPS = 128 };

typedef struct {
	uintptr_t id;
	int px[4];        // where the page is, in the view's real pixels
	int shown;
	GdkTexture *tex;  // the last frame
	guchar *buf;      // the whole frame (BGRA, premultiplied), updated by parts
	int bw, bh;
	char *cursor;
} EV;

static GtkWidget *host;
static GHashTable *views; // id -> EV*

// ---- newer GTK, when the system has it ----

typedef struct _GdkMemoryTextureBuilder MemBuilder;
#if !GTK_CHECK_VERSION(4, 8, 0)
typedef enum { GDK_SCROLL_UNIT_WHEEL, GDK_SCROLL_UNIT_SURFACE } GdkScrollUnit;
#endif
static GdkScrollUnit (*p_scroll_unit)(GdkEvent *);
static MemBuilder *(*p_mtb_new)(void);
static void (*p_mtb_set_bytes)(MemBuilder *, GBytes *);
static void (*p_mtb_set_stride)(MemBuilder *, gsize);
static void (*p_mtb_set_width)(MemBuilder *, int);
static void (*p_mtb_set_height)(MemBuilder *, int);
static void (*p_mtb_set_format)(MemBuilder *, GdkMemoryFormat);
static void (*p_mtb_set_update_texture)(MemBuilder *, GdkTexture *);
static void (*p_mtb_set_update_region)(MemBuilder *, cairo_region_t *);
static GdkTexture *(*p_mtb_build)(MemBuilder *);
static double (*p_surface_get_scale)(GdkSurface *);
static void (*p_append_scaled)(GtkSnapshot *, GdkTexture *, GskScalingFilter, const graphene_rect_t *);

static void loadSyms(void) {
	static int done;
	if (done) return;
	done = 1;
#define SYM(p, n) p = dlsym(RTLD_DEFAULT, n)
	SYM(p_mtb_new, "gdk_memory_texture_builder_new");
	SYM(p_mtb_set_bytes, "gdk_memory_texture_builder_set_bytes");
	SYM(p_mtb_set_stride, "gdk_memory_texture_builder_set_stride");
	SYM(p_mtb_set_width, "gdk_memory_texture_builder_set_width");
	SYM(p_mtb_set_height, "gdk_memory_texture_builder_set_height");
	SYM(p_mtb_set_format, "gdk_memory_texture_builder_set_format");
	SYM(p_mtb_set_update_texture, "gdk_memory_texture_builder_set_update_texture");
	SYM(p_mtb_set_update_region, "gdk_memory_texture_builder_set_update_region");
	SYM(p_mtb_build, "gdk_memory_texture_builder_build");
	SYM(p_surface_get_scale, "gdk_surface_get_scale");
	SYM(p_append_scaled, "gtk_snapshot_append_scaled_texture");
	SYM(p_scroll_unit, "gdk_scroll_event_get_unit");
#undef SYM
	if (!p_mtb_new || !p_mtb_set_bytes || !p_mtb_set_stride || !p_mtb_set_width || !p_mtb_set_height || !p_mtb_set_format ||
	    !p_mtb_set_update_texture || !p_mtb_set_update_region || !p_mtb_build)
		p_mtb_new = NULL;
}

// The scale GTK really draws the window at (see cmd/iris/gtk_linux.c).
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
	loadSyms();
	GtkNative *n = host ? gtk_widget_get_native(host) : NULL;
	GdkSurface *s = n ? gtk_native_get_surface(n) : NULL;
	if (!s) return host ? gtk_widget_get_scale_factor(host) : 1;
	double sc = p_surface_get_scale && drawsFractional() ? p_surface_get_scale(s) : gdk_surface_get_scale_factor(s);
	return sc > 0.25 ? sc : 1;
}

// elxScale is the window's scale now; Electron draws the pages at it.
double elxScale(void) { return scaleOf(); }

static EV *ev(uintptr_t id, int make) {
	if (!views) views = g_hash_table_new(g_direct_hash, g_direct_equal);
	EV *v = g_hash_table_lookup(views, (gpointer)id);
	if (!v && make) {
		v = g_new0(EV, 1);
		v->id = id;
		g_hash_table_insert(views, (gpointer)id, v);
	}
	return v;
}

static void redraw(void) {
	if (host) gtk_widget_queue_draw(host);
}

// ---- Go's calls, moved to GTK's thread ----

typedef struct {
	int op;
	uintptr_t id;
	int a, b, c, d;
	int fw, fh, stride;
	guchar *pix;
	char *s;
} Job;

enum { J_PLACE = 1, J_SHOW, J_DROP, J_PAINT, J_CURSOR, J_FOCUS };

static EV *focusPage, *hoverPage, *grabPage;
static GtkIMContext *pageIM;

static void forget(EV *v) {
	if (focusPage == v) focusPage = NULL;
	if (hoverPage == v) hoverPage = NULL;
	if (grabPage == v) grabPage = NULL;
}

static void applyPaint(EV *v, Job *j) {
	// the whole frame, kept here; a part replaces its rectangle in it
	int fw = j->fw, fh = j->fh;
	if (!v->buf || v->bw != fw || v->bh != fh) {
		g_free(v->buf);
		v->buf = g_malloc0((gsize)fw * fh * 4);
		v->bw = fw, v->bh = fh;
		g_clear_object(&v->tex);
	}
	int x = CLAMP(j->a, 0, fw), y = CLAMP(j->b, 0, fh);
	int w = MIN(j->c, fw - x), h = MIN(j->d, fh - y);
	for (int r = 0; r < h; r++) memcpy(v->buf + ((gsize)(y + r) * fw + x) * 4, j->pix + (gsize)r * j->stride, (gsize)w * 4);
	GBytes *bytes = g_bytes_new(v->buf, (gsize)fw * fh * 4);
	GdkTexture *t;
	if (p_mtb_new) {
		MemBuilder *b = p_mtb_new();
		p_mtb_set_bytes(b, bytes);
		p_mtb_set_stride(b, (gsize)fw * 4);
		p_mtb_set_width(b, fw);
		p_mtb_set_height(b, fh);
		p_mtb_set_format(b, GDK_MEMORY_B8G8R8A8_PREMULTIPLIED);
		if (v->tex && w > 0 && h > 0) {
			// only the part that changed goes to the graphics chip
			cairo_rectangle_int_t c = {x, y, w, h};
			cairo_region_t *r = cairo_region_create_rectangle(&c);
			p_mtb_set_update_texture(b, v->tex);
			p_mtb_set_update_region(b, r);
			cairo_region_destroy(r);
		}
		t = p_mtb_build(b);
		g_object_unref(b);
	} else {
		t = gdk_memory_texture_new(fw, fh, GDK_MEMORY_B8G8R8A8_PREMULTIPLIED, bytes, (gsize)fw * 4);
	}
	g_bytes_unref(bytes);
	if (v->tex) g_object_unref(v->tex);
	v->tex = t;
}

static gboolean runJob(gpointer d) {
	Job *j = d;
	EV *v = ev(j->id, j->op != J_DROP && j->op != J_PAINT && j->op != J_CURSOR);
	switch (j->op) {
	case J_PLACE:
		if (v) v->px[0] = j->a, v->px[1] = j->b, v->px[2] = j->c, v->px[3] = j->d;
		break;
	case J_SHOW:
		if (v) v->shown = j->a;
		break;
	case J_DROP:
		if (v) {
			forget(v);
			g_hash_table_remove(views, (gpointer)j->id);
			g_clear_object(&v->tex);
			g_free(v->buf);
			g_free(v->cursor);
			g_free(v);
		}
		break;
	case J_PAINT:
		if (v) applyPaint(v, j);
		break;
	case J_CURSOR:
		if (v) {
			g_free(v->cursor);
			v->cursor = j->s, j->s = NULL;
			if (hoverPage == v && host) gtk_widget_set_cursor_from_name(host, v->cursor);
		}
		break;
	case J_FOCUS:
		if (v) {
			focusPage = v;
			if (pageIM) gtk_im_context_focus_in(pageIM);
		}
		break;
	}
	if (j->op != J_FOCUS && j->op != J_CURSOR && (!v || v->shown || j->op == J_SHOW)) redraw();
	free(j->pix); // malloc'd by Go
	g_free(j->s);
	g_free(j);
	return G_SOURCE_REMOVE;
}

static void post(Job *j) { g_main_context_invoke(NULL, runJob, j); }

void elxPlace(uintptr_t id, int x, int y, int w, int h) {
	Job *j = g_new0(Job, 1);
	*j = (Job){.op = J_PLACE, .id = id, .a = x, .b = y, .c = w, .d = h};
	post(j);
}

void elxShow(uintptr_t id, int on) {
	Job *j = g_new0(Job, 1);
	*j = (Job){.op = J_SHOW, .id = id, .a = on};
	post(j);
}

void elxDrop(uintptr_t id) {
	Job *j = g_new0(Job, 1);
	*j = (Job){.op = J_DROP, .id = id};
	post(j);
}

void elxFocusPage(uintptr_t id) {
	Job *j = g_new0(Job, 1);
	*j = (Job){.op = J_FOCUS, .id = id};
	post(j);
}

// elxPaint takes a part of a page's frame: (x, y, w, h) of a fw × fh frame,
// rows stride bytes apart in pix (malloc'd; freed here).
void elxPaint(uintptr_t id, int fw, int fh, int x, int y, int w, int h, int stride, void *pix) {
	Job *j = g_new0(Job, 1);
	*j = (Job){.op = J_PAINT, .id = id, .a = x, .b = y, .c = w, .d = h, .fw = fw, .fh = fh, .stride = stride, .pix = pix};
	post(j);
}

void elxCursor(uintptr_t id, const char *name) {
	Job *j = g_new0(Job, 1);
	*j = (Job){.op = J_CURSOR, .id = id, .s = g_strdup(name && *name ? name : "default")};
	post(j);
}

// ---- drawing ----

static void appendTexture(GtkSnapshot *s, GdkTexture *t, const graphene_rect_t *r, int sharp) {
	if (p_append_scaled) p_append_scaled(s, t, sharp ? GSK_SCALING_FILTER_NEAREST : GSK_SCALING_FILTER_LINEAR, r);
	else gtk_snapshot_append_texture(s, t, r);
}

void lgxSnapshotPages(GtkSnapshot *sn, double s) {
	if (!views || s <= 0) return;
	GHashTableIter it;
	gpointer k, val;
	g_hash_table_iter_init(&it, views);
	while (g_hash_table_iter_next(&it, &k, &val)) {
		EV *v = val;
		if (!v->shown || v->px[2] <= 0 || v->px[3] <= 0) continue;
		graphene_rect_t r = GRAPHENE_RECT_INIT(v->px[0] / s, v->px[1] / s, v->px[2] / s, v->px[3] / s);
		// a page has rounded corners like the glass around it (none full screen)
		GskRoundedRect rr;
		gsk_rounded_rect_init_from_rect(&rr, &r, v->px[0] == 0 && v->px[1] == 0 ? 0 : 12);
		gtk_snapshot_push_rounded_clip(sn, &rr);
		if (v->tex) {
			int tw = gdk_texture_get_width(v->tex), th = gdk_texture_get_height(v->tex);
			if (abs(tw - v->px[2]) <= 1 && abs(th - v->px[3]) <= 1)
				appendTexture(sn, v->tex, &GRAPHENE_RECT_INIT(r.origin.x, r.origin.y, tw / s, th / s), 1); // one texel on one pixel
			else
				appendTexture(sn, v->tex, &r, 0); // a new size's frame is on its way
		} else {
			GdkRGBA white = {1, 1, 1, 1};
			gtk_snapshot_append_color(sn, &white, &r);
		}
		gtk_snapshot_pop(sn);
	}
}

// ---- input ----

static guint32 lastClickTime;
static double lastClickX, lastClickY;
static int lastClickButton, clickCount;

static unsigned modsOf(guint state) {
	unsigned m = 0;
	if (state & GDK_SHIFT_MASK) m |= M_SHIFT;
	if (state & GDK_CONTROL_MASK) m |= M_CTRL;
	if (state & GDK_ALT_MASK) m |= M_ALT;
	if (state & (GDK_SUPER_MASK | GDK_META_MASK)) m |= M_META;
	if (state & GDK_BUTTON1_MASK) m |= M_LEFT;
	if (state & GDK_BUTTON2_MASK) m |= M_MIDDLE;
	if (state & GDK_BUTTON3_MASK) m |= M_RIGHT;
	if (state & GDK_LOCK_MASK) m |= M_CAPS;
	return m;
}

static EV *pageAt(double x, double y) {
	double s = scaleOf(), px = x * s, py = y * s;
	GHashTableIter it;
	gpointer k, val;
	g_hash_table_iter_init(&it, views);
	while (g_hash_table_iter_next(&it, &k, &val)) {
		EV *v = val;
		if (v->shown && px >= v->px[0] && py >= v->px[1] && px < v->px[0] + v->px[2] && py < v->px[1] + v->px[3]) return v;
	}
	return NULL;
}

// inPage is (x, y) of the view in the page's own units (CSS pixels at zoom 1).
// inPage is where (x, y) falls in page v, in screen pixels: pages are drawn
// at scale 1 and zoomed by the window's scale, so their own coordinates are
// screen pixels.
static void inPage(EV *v, double x, double y, double *ox, double *oy) {
	double s = scaleOf();
	*ox = x * s - v->px[0];
	*oy = y * s - v->px[1];
}

static void setCursor(const char *name) {
	if (host) gtk_widget_set_cursor_from_name(host, name);
}

void lgxUIFocus(void) {
	if (focusPage && pageIM) gtk_im_context_focus_out(pageIM);
	focusPage = NULL;
}

void lgxPagesLeave(void) {
	if (hoverPage && !grabPage) {
		elxGoMouse(hoverPage->id, 3, -1, -1, 0, 0, 0);
		hoverPage = NULL;
		setCursor(NULL);
	}
}

int lgxPagePointer(GdkEvent *e, double x, double y) {
	if (!views) return 0;
	GdkEventType t = gdk_event_get_event_type(e);
	guint state = gdk_event_get_modifier_state(e);
	EV *v = grabPage ? grabPage : pageAt(x, y);
	if (hoverPage && hoverPage != v && g_hash_table_lookup(views, (gpointer)hoverPage->id) == hoverPage)
		elxGoMouse(hoverPage->id, 3, -1, -1, 0, 0, modsOf(state));
	if (v != hoverPage) {
		hoverPage = v;
		setCursor(v ? v->cursor : NULL);
	}
	if (!v) return 0;
	double px, py;
	inPage(v, x, y, &px, &py);
	switch (t) {
	case GDK_BUTTON_PRESS:
	case GDK_BUTTON_RELEASE: {
		guint button = gdk_button_event_get_button(e);
		int press = t == GDK_BUTTON_PRESS;
		if (button == 8 || button == 9) { // the mouse's back and forward buttons
			if (press) elxGoNav(v->id, button == 9);
			break;
		}
		int b = button == 2 ? 1 : button == 3 ? 2 : 0;
		if (press) {
			if (focusPage != v) {
				focusPage = v;
				if (pageIM) gtk_im_context_focus_in(pageIM);
			}
			lgxGoFocus(v->id);
			guint32 now = gdk_event_get_time(e);
			double dx = x - lastClickX, dy = y - lastClickY;
			if ((int)button == lastClickButton && now - lastClickTime < 400 && dx * dx + dy * dy < 25) clickCount = clickCount % 3 + 1;
			else clickCount = 1;
			lastClickTime = now, lastClickX = x, lastClickY = y, lastClickButton = (int)button;
			grabPage = v;
		} else {
			grabPage = NULL;
		}
		elxGoMouse(v->id, press ? 1 : 2, px, py, b, clickCount ? clickCount : 1, modsOf(state));
		break;
	}
	case GDK_MOTION_NOTIFY:
		elxGoMouse(v->id, 0, px, py, 0, 0, modsOf(state));
		break;
	case GDK_SCROLL: {
		// a touchpad's two-finger scroll comes as many small moves, often
		// under a pixel each: what is left over is kept for the next move
		static EV *accPage;
		static double accX, accY;
		if (accPage != v) accPage = v, accX = accY = 0;
		double dx = 0, dy = 0;
		int precise = 0;
		const double tick = 40; // pixels for one notch of the wheel
		switch (gdk_scroll_event_get_direction(e)) {
		case GDK_SCROLL_UP: dy = tick; break;
		case GDK_SCROLL_DOWN: dy = -tick; break;
		case GDK_SCROLL_LEFT: dx = tick; break;
		case GDK_SCROLL_RIGHT: dx = -tick; break;
		case GDK_SCROLL_SMOOTH: {
			double ex = 0, ey = 0;
			gdk_scroll_event_get_deltas(e, &ex, &ey);
			if (p_scroll_unit) precise = p_scroll_unit(e) == 1;
			else {
				GdkDevice *dev = gdk_event_get_device(e);
				GdkInputSource src = dev ? gdk_device_get_source(dev) : GDK_SOURCE_MOUSE;
				precise = src == GDK_SOURCE_TOUCHPAD || src == GDK_SOURCE_TOUCHSCREEN || src == GDK_SOURCE_TRACKPOINT;
			}
			double k = precise ? 1 : tick;
			dx = -ex * k, dy = -ey * k;
			if (gdk_scroll_event_is_stop(e)) accX = accY = 0;
			break;
		}
		}
		if ((state & GDK_SHIFT_MASK) && dx == 0) dx = dy, dy = 0; // Shift + wheel scrolls sideways
		dx *= scaleOf(), dy *= scaleOf(); // in screen pixels, like the page
		accX += dx, accY += dy;
		double sx = trunc(accX), sy = trunc(accY);
		accX -= sx, accY -= sy;
		if (g_getenv("IRIS_INPUT_DEBUG")) g_printerr("Iris: page scroll %+.2f %+.2f sent %.0f %.0f precise %d\n", dx, dy, sx, sy, precise);
		if (sx != 0 || sy != 0) elxGoWheel(v->id, px, py, sx, sy, precise, modsOf(state));
		break;
	}
	default:
		break;
	}
	return 1;
}

// keyName is Electron's name for a key (an accelerator's key code); NULL
// for keys that only type text.
static const char *keyName(guint kv, char *buf) {
	if (kv >= GDK_KEY_a && kv <= GDK_KEY_z) return buf[0] = 'A' + (kv - GDK_KEY_a), buf[1] = 0, buf;
	if (kv >= GDK_KEY_A && kv <= GDK_KEY_Z) return buf[0] = 'A' + (kv - GDK_KEY_A), buf[1] = 0, buf;
	if (kv >= GDK_KEY_0 && kv <= GDK_KEY_9) return buf[0] = '0' + (kv - GDK_KEY_0), buf[1] = 0, buf;
	if (kv >= GDK_KEY_F1 && kv <= GDK_KEY_F24) return snprintf(buf, 8, "F%u", kv - GDK_KEY_F1 + 1), buf;
	switch (kv) {
	case GDK_KEY_BackSpace: return "Backspace";
	case GDK_KEY_Tab: case GDK_KEY_ISO_Left_Tab: return "Tab";
	case GDK_KEY_Return: case GDK_KEY_KP_Enter: return "Enter";
	case GDK_KEY_Escape: return "Escape";
	case GDK_KEY_space: return "Space";
	case GDK_KEY_Page_Up: case GDK_KEY_KP_Page_Up: return "PageUp";
	case GDK_KEY_Page_Down: case GDK_KEY_KP_Page_Down: return "PageDown";
	case GDK_KEY_End: case GDK_KEY_KP_End: return "End";
	case GDK_KEY_Home: case GDK_KEY_KP_Home: return "Home";
	case GDK_KEY_Left: case GDK_KEY_KP_Left: return "Left";
	case GDK_KEY_Up: case GDK_KEY_KP_Up: return "Up";
	case GDK_KEY_Right: case GDK_KEY_KP_Right: return "Right";
	case GDK_KEY_Down: case GDK_KEY_KP_Down: return "Down";
	case GDK_KEY_Insert: case GDK_KEY_KP_Insert: return "Insert";
	case GDK_KEY_Delete: case GDK_KEY_KP_Delete: return "Delete";
	case GDK_KEY_Shift_L: case GDK_KEY_Shift_R: return "Shift";
	case GDK_KEY_Control_L: case GDK_KEY_Control_R: return "Control";
	case GDK_KEY_Alt_L: case GDK_KEY_Alt_R: return "Alt";
	case GDK_KEY_Super_L: case GDK_KEY_Super_R: return "Super";
	case GDK_KEY_Caps_Lock: return "Capslock";
	case GDK_KEY_Num_Lock: return "Numlock";
	case GDK_KEY_Menu: return "ContextMenu";
	case GDK_KEY_minus: case GDK_KEY_KP_Subtract: return "-";
	case GDK_KEY_plus: case GDK_KEY_KP_Add: return "Plus";
	case GDK_KEY_equal: return "=";
	case GDK_KEY_comma: return ",";
	case GDK_KEY_period: case GDK_KEY_KP_Decimal: return ".";
	case GDK_KEY_slash: case GDK_KEY_KP_Divide: return "/";
	case GDK_KEY_semicolon: return ";";
	case GDK_KEY_apostrophe: return "'";
	case GDK_KEY_bracketleft: return "[";
	case GDK_KEY_bracketright: return "]";
	case GDK_KEY_backslash: return "\\";
	case GDK_KEY_grave: return "`";
	}
	return NULL;
}

// the Windows key code Iris's shortcut table uses, for the keys it checks
static int shortcutVK(guint kv) {
	switch (kv) {
	case GDK_KEY_Left: return 0x25;
	case GDK_KEY_Right: return 0x27;
	case GDK_KEY_F5: return 0x74;
	case GDK_KEY_F6: return 0x75;
	case GDK_KEY_F11: return 0x7A;
	case GDK_KEY_Tab: case GDK_KEY_ISO_Left_Tab: return 0x09;
	case GDK_KEY_Page_Up: return 0x21;
	case GDK_KEY_Page_Down: return 0x22;
	case GDK_KEY_Back: return 0xA6;
	case GDK_KEY_Forward: return 0xA7;
	}
	return 0;
}

static void onCommit(GtkIMContext *im, const char *text, gpointer d) {
	if (focusPage) elxGoChar(focusPage->id, (char *)text, 0);
}

int lgxPageKey(GdkEvent *e) {
	EV *v = focusPage;
	if (!v || !views || g_hash_table_lookup(views, (gpointer)v->id) != v || !v->shown) return 0;
	GdkEventType type = gdk_event_get_event_type(e);
	guint state = gdk_event_get_modifier_state(e), kv = gdk_key_event_get_keyval(e);
	int ctrl = (state & GDK_CONTROL_MASK) != 0, shift = (state & GDK_SHIFT_MASK) != 0, alt = (state & GDK_ALT_MASK) != 0;
	unsigned mods = modsOf(state);
	char buf[8];
	const char *name = keyName(kv, buf);
	if (type == GDK_KEY_PRESS) {
		// Iris's own shortcuts first (Ctrl+T, Ctrl+L, F5, Alt+Left and so on)
		int vk = shortcutVK(kv);
		gunichar lc = gdk_keyval_to_unicode(gdk_keyval_to_lower(kv));
		if ((ctrl || alt || vk) && lgxGoKey(v->id, (int)lc, vk, ctrl, shift, alt)) return 1;
		if (name) elxGoKeyEv(v->id, 1, (char *)name, mods);
		// typed text goes through the input method (dead keys: ´ then e is é)
		if (!ctrl && !alt && pageIM && gtk_im_context_filter_keypress(pageIM, e)) return 1;
		gunichar ch = gdk_keyval_to_unicode(kv);
		if (kv == GDK_KEY_Return || kv == GDK_KEY_KP_Enter) ch = '\r';
		if (ch && ch != 0x7f && !(ctrl && !alt) && (ch >= 0x20 || ch == '\r' || ch == '\t')) {
			char t[8] = {0};
			g_unichar_to_utf8(ch, t);
			elxGoChar(v->id, t, mods);
		}
	} else {
		if (pageIM) gtk_im_context_filter_keypress(pageIM, e);
		if (name) elxGoKeyEv(v->id, 0, (char *)name, mods);
	}
	return 1;
}

// elxOnMain runs Go's function h on GTK's thread.
static gboolean runGo(gpointer h) {
	elxGoRun((uintptr_t)h);
	return G_SOURCE_REMOVE;
}
void elxOnMain(uintptr_t h) { g_main_context_invoke(NULL, runGo, (gpointer)h); }

// lgxAttach is Iris's window: view is the widget the pages are drawn in.
void lgxAttach(uintptr_t view, const char *dataDir) {
	loadSyms();
	host = GTK_WIDGET((void *)view);
	if (!views) views = g_hash_table_new(g_direct_hash, g_direct_equal);
	if (!pageIM) {
		pageIM = gtk_im_multicontext_new();
		gtk_im_context_set_client_widget(pageIM, host);
		g_signal_connect(pageIM, "commit", G_CALLBACK(onCommit), NULL);
	}
}
