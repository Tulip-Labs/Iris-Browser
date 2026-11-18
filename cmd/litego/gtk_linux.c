//go:build linux && webkit

// The Linux window of Iris, made with GTK 4 so that it runs natively on
// Wayland (niri, Sway, Hyprland, KDE, GNOME) as well as on X11.
//
// The window holds one widget, the view, which draws everything at the
// screen's exact scale, fractional ones (1.25, 1.5, 1.75) included:
//   - Iris's interface, drawn by Gio's GPU renderer into a texture of the
//     view's size in real pixels;
//   - over it each page, drawn by Chromium off screen at that same scale and
//     placed on whole pixels (webview/cef_linux.c, lgxSnapshotPages), so one
//     page pixel is one screen pixel: sharp, and no larger than it must be.
// The pointer, the wheel and the keys go to the page under them (or the
// focused one), else to the interface.
//
// The window draws its own title bar (ours). Client-side decorations with an
// empty GTK title bar keep the system's shadow, rounded corners and resize
// edges.

#define _GNU_SOURCE // RTLD_DEFAULT
#include <dlfcn.h>
#include <epoxy/gl.h>
#include <gtk/gtk.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

extern void lgwGoRender(int w, int h, double sf, unsigned int fbo);
extern void lgwGoUnrealize(void);
extern void lgwGoAfter(void);
extern int lgwGoButton(double x, double y, int button, int press, unsigned int state, int touch);
extern void lgwGoMotion(double x, double y, unsigned int state, int touch);
extern void lgwGoLeave(void);
extern void lgwGoScroll(double dx, double dy, int smooth, unsigned int state, int touch);
extern void lgwGoPinch(int phase, double scale, double x, double y);
extern int lgwGoKey(unsigned int keyval, unsigned int state);
extern void lgwGoText(char *s);
extern void lgwGoPaste(char *s);
extern void lgwGoState(int maximized, int fullscreen, int w, int h);
extern void lgwGoDestroy(void);
extern void lgwGoClose(void);
extern void lgwGoDo(uintptr_t h);
extern void lgwGoScale(double sf, double text);

// the pages (webview/cef_linux.c)
extern void lgxSnapshotPages(GtkSnapshot *s, double scale) __attribute__((weak));
extern int lgxPagePointer(GdkEvent *e, double x, double y) __attribute__((weak));
extern int lgxPageKey(GdkEvent *e) __attribute__((weak));
extern void lgxPagesLeave(void) __attribute__((weak));
extern void lgxUIFocus(void) __attribute__((weak));

// ---- newer GTK, when the system has it ----
//
// Iris is built against the oldest GTK 4 it supports (4.6, Ubuntu 22.04), and
// uses what newer ones add when they are there: the screen's fractional scale
// (4.12), GL textures with a fence (4.12), smooth scaling choices (4.10).

static void *sym(const char *n) { return dlsym(RTLD_DEFAULT, n); }

#if !GTK_CHECK_VERSION(4, 8, 0)
typedef enum { GDK_SCROLL_UNIT_WHEEL, GDK_SCROLL_UNIT_SURFACE } GdkScrollUnit;
#endif

typedef struct _GdkGLTextureBuilder GdkGLTextureBuilder_;
static double (*p_surface_get_scale)(GdkSurface *);
static GdkGLTextureBuilder_ *(*p_gltb_new)(void);
static void (*p_gltb_set_context)(GdkGLTextureBuilder_ *, GdkGLContext *);
static void (*p_gltb_set_id)(GdkGLTextureBuilder_ *, guint);
static void (*p_gltb_set_width)(GdkGLTextureBuilder_ *, int);
static void (*p_gltb_set_height)(GdkGLTextureBuilder_ *, int);
static void (*p_gltb_set_sync)(GdkGLTextureBuilder_ *, gpointer);
static GdkTexture *(*p_gltb_build)(GdkGLTextureBuilder_ *, GDestroyNotify, gpointer);
static void (*p_append_scaled)(GtkSnapshot *, GdkTexture *, GskScalingFilter, const graphene_rect_t *);
static GdkScrollUnit (*p_scroll_unit)(GdkEvent *);

static void loadSyms(void) {
	static int done;
	if (done) return;
	done = 1;
	p_surface_get_scale = sym("gdk_surface_get_scale");
	p_gltb_new = sym("gdk_gl_texture_builder_new");
	p_gltb_set_context = sym("gdk_gl_texture_builder_set_context");
	p_gltb_set_id = sym("gdk_gl_texture_builder_set_id");
	p_gltb_set_width = sym("gdk_gl_texture_builder_set_width");
	p_gltb_set_height = sym("gdk_gl_texture_builder_set_height");
	p_gltb_set_sync = sym("gdk_gl_texture_builder_set_sync");
	p_gltb_build = sym("gdk_gl_texture_builder_build");
	p_append_scaled = sym("gtk_snapshot_append_scaled_texture");
	p_scroll_unit = sym("gdk_scroll_event_get_unit");
	if (!p_gltb_new || !p_gltb_set_context || !p_gltb_set_id || !p_gltb_set_width || !p_gltb_set_height || !p_gltb_set_sync || !p_gltb_build)
		p_gltb_new = NULL;
}

// ---- the window and its view ----

static GtkWidget *win, *view;
static GtkIMContext *im;
static int uiDirty = 1; // the interface asked for a new frame

typedef struct {
	GtkWidget parent;
} IrisView;
typedef struct {
	GtkWidgetClass parent;
} IrisViewClass;
G_DEFINE_TYPE(IrisView, iris_view, GTK_TYPE_WIDGET)

// scaleOf is the view's scale: real pixels per GTK unit, fractional where
// the system draws fractionally.
static double scaleOf(GtkWidget *w) {
	GtkNative *n = w ? gtk_widget_get_native(w) : NULL;
	GdkSurface *s = n ? gtk_native_get_surface(n) : NULL;
	if (!s) return w ? gtk_widget_get_scale_factor(w) : 1;
	double sc = p_surface_get_scale ? p_surface_get_scale(s) : gdk_surface_get_scale_factor(s);
	return sc > 0.25 ? sc : 1;
}

// origin is where the view starts on its window's surface (past the shadow
// of client-side decorations), in GTK units.
static void origin(GtkWidget *w, double *x, double *y) {
	*x = *y = 0;
	GtkNative *n = gtk_widget_get_native(w);
	if (!n) return;
	double nx = 0, ny = 0;
	gtk_native_get_surface_transform(n, &nx, &ny);
	graphene_point_t p = GRAPHENE_POINT_INIT(0, 0), q;
	if (gtk_widget_compute_point(w, GTK_WIDGET(n), &p, &q)) *x = q.x + nx, *y = q.y + ny;
}

// The interface's frames: Gio draws into a texture of the view's size in
// real pixels, on a GL context of the view's own. Textures GTK still shows
// are kept; the others are drawn into again.

typedef struct {
	GLuint id;
	int w, h;
	int busy; // GTK still holds a texture made from it
	gpointer sync;
} UITex;

static GdkGLContext *glc;
static GLuint uiFbo;
static UITex pool[3];
static GdkTexture *uiTex; // the last frame
static int uiW, uiH;
static double uiS;
static int glFailed;

// GTK let go of a frame (its fence is deleted when the texture is drawn
// into again, on this thread with the context current)
static void released(gpointer d) { __atomic_store_n(&((UITex *)d)->busy, 0, __ATOMIC_SEQ_CST); }

static GdkGLContext *context(GtkWidget *w) {
	if (glc || glFailed) return glc;
	GtkNative *n = gtk_widget_get_native(w);
	GdkSurface *s = n ? gtk_native_get_surface(n) : NULL;
	if (!s) return NULL;
	GError *err = NULL;
	glc = gdk_surface_create_gl_context(s, &err);
	if (glc) {
		// OpenGL ES, as Gio's renderer expects (its shaders are GLSL ES)
		gdk_gl_context_set_use_es(glc, 1);
		if (!gdk_gl_context_realize(glc, &err)) {
			g_clear_error(&err);
			gdk_gl_context_set_use_es(glc, -1);
			if (!gdk_gl_context_realize(glc, &err)) g_clear_object(&glc);
		}
	}
	if (!glc) {
		g_printerr("Iris: no OpenGL context: %s\n", err ? err->message : "?");
		g_clear_error(&err);
		glFailed = 1;
		return NULL;
	}
	gdk_gl_context_make_current(glc);
	if (g_getenv("LITEGO_GL_DEBUG"))
		g_printerr("Iris: GL %s | %s | es=%d | GTK %d.%d.%d\n", (const char *)glGetString(GL_VERSION), (const char *)glGetString(GL_RENDERER),
		           gdk_gl_context_get_use_es(glc), gtk_get_major_version(), gtk_get_minor_version(), gtk_get_micro_version());
	return glc;
}

static void renderUI(GtkWidget *w, int pw, int ph, double s) {
	if (!context(w)) return;
	gdk_gl_context_make_current(glc);
	UITex *t = NULL;
	for (int i = 0; i < 3 && !t; i++)
		if (!__atomic_load_n(&pool[i].busy, __ATOMIC_SEQ_CST) && pool[i].id && pool[i].w == pw && pool[i].h == ph) t = &pool[i];
	for (int i = 0; i < 3 && !t; i++)
		if (!__atomic_load_n(&pool[i].busy, __ATOMIC_SEQ_CST)) t = &pool[i];
	if (!t) return; // GTK holds all three: this frame waits for the next
	if (t->sync) {
		glDeleteSync(t->sync);
		t->sync = NULL;
	}
	if (!t->id || t->w != pw || t->h != ph) {
		if (t->id) glDeleteTextures(1, &t->id);
		glGenTextures(1, &t->id);
		glBindTexture(GL_TEXTURE_2D, t->id);
		glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, pw, ph, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
		t->w = pw, t->h = ph;
	}
	if (!uiFbo) glGenFramebuffers(1, &uiFbo);
	glBindFramebuffer(GL_FRAMEBUFFER, uiFbo);
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, t->id, 0);
	if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
		g_printerr("Iris: the interface's frame cannot be drawn into\n");
		glBindFramebuffer(GL_FRAMEBUFFER, 0);
		return;
	}
	glViewport(0, 0, pw, ph);
	glDisable(GL_SCISSOR_TEST);
	glClearColor(0.07f, 0.07f, 0.08f, 1);
	glClear(GL_COLOR_BUFFER_BIT); // what shows if the interface is not ready yet
	lgwGoRender(pw, ph, s, uiFbo);
	// an opaque window: whatever Gio left see-through is not
	gdk_gl_context_make_current(glc);
	glBindFramebuffer(GL_FRAMEBUFFER, uiFbo);
	glDisable(GL_SCISSOR_TEST);
	glColorMask(GL_FALSE, GL_FALSE, GL_FALSE, GL_TRUE);
	glClearColor(0, 0, 0, 1);
	glClear(GL_COLOR_BUFFER_BIT);
	glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
	glBindFramebuffer(GL_FRAMEBUFFER, 0);
	GdkTexture *tex;
	t->busy = 1;
	// a fence needs OpenGL ES 3 (or desktop GL 3.2)
	int fence = epoxy_is_desktop_gl() ? epoxy_gl_version() >= 32 : epoxy_gl_version() >= 30;
	if (p_gltb_new && fence) {
		GdkGLTextureBuilder_ *b = p_gltb_new();
		p_gltb_set_context(b, glc);
		p_gltb_set_id(b, t->id);
		p_gltb_set_width(b, pw);
		p_gltb_set_height(b, ph);
		t->sync = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
		p_gltb_set_sync(b, t->sync);
		tex = p_gltb_build(b, released, t);
		g_object_unref(b);
	} else {
		glFinish(); // older GTK reads the texture without a fence
		G_GNUC_BEGIN_IGNORE_DEPRECATIONS
		tex = gdk_gl_texture_new(glc, t->id, pw, ph, released, t);
		G_GNUC_END_IGNORE_DEPRECATIONS
	}
	if (uiTex) g_object_unref(uiTex);
	uiTex = tex;
	uiW = pw, uiH = ph, uiS = s;
}

static void appendTexture(GtkSnapshot *s, GdkTexture *t, const graphene_rect_t *r, int sharp) {
	if (p_append_scaled) p_append_scaled(s, t, sharp ? GSK_SCALING_FILTER_NEAREST : GSK_SCALING_FILTER_LINEAR, r);
	else gtk_snapshot_append_texture(s, t, r);
}

static void iris_view_snapshot(GtkWidget *w, GtkSnapshot *sn) {
	int W = gtk_widget_get_width(w), H = gtk_widget_get_height(w);
	if (W <= 0 || H <= 0) return;
	double s = scaleOf(w);
	int pw = (int)ceil(W * s - 0.01), ph = (int)ceil(H * s - 0.01);
	if (uiDirty || !uiTex || pw != uiW || ph != uiH || fabs(s - uiS) > 0.001) {
		uiDirty = 0;
		renderUI(w, pw, ph, s);
	}
	// on whole pixels of the screen: the view may start between two
	// (fractional scales, the decorations' shadow)
	double ox, oy;
	origin(w, &ox, &oy);
	double dx = (round(ox * s) - ox * s) / s, dy = (round(oy * s) - oy * s) / s;
	graphene_rect_t all = GRAPHENE_RECT_INIT(0, 0, W, H);
	gtk_snapshot_push_clip(sn, &all);
	gtk_snapshot_save(sn);
	gtk_snapshot_translate(sn, &GRAPHENE_POINT_INIT(dx, dy));
	if (uiTex && uiW == pw && uiH == ph) {
		// a GL texture is upside down to GTK: flipped back
		gtk_snapshot_save(sn);
		gtk_snapshot_translate(sn, &GRAPHENE_POINT_INIT(0, ph / s));
		gtk_snapshot_scale(sn, 1, -1);
		appendTexture(sn, uiTex, &GRAPHENE_RECT_INIT(0, 0, pw / s, ph / s), 1);
		gtk_snapshot_restore(sn);
	} else {
		GdkRGBA bg = {0.07, 0.07, 0.08, 1};
		gtk_snapshot_append_color(sn, &bg, &all);
	}
	if (lgxSnapshotPages) lgxSnapshotPages(sn, s);
	gtk_snapshot_restore(sn);
	gtk_snapshot_pop(sn);
}

static void iris_view_unrealize(GtkWidget *w) {
	if (glc) {
		gdk_gl_context_make_current(glc);
		lgwGoUnrealize();
		gdk_gl_context_make_current(glc);
		for (int i = 0; i < 3; i++) {
			if (pool[i].id) glDeleteTextures(1, &pool[i].id);
			if (pool[i].sync) glDeleteSync(pool[i].sync);
			pool[i] = (UITex){0};
		}
		if (uiFbo) glDeleteFramebuffers(1, &uiFbo);
		uiFbo = 0;
	}
	g_clear_object(&uiTex);
	g_clear_object(&glc);
	uiW = uiH = 0;
	GTK_WIDGET_CLASS(iris_view_parent_class)->unrealize(w);
}

// the pages' right-click menus are popovers of the view: placed here
static void iris_view_size_allocate(GtkWidget *w, int width, int height, int baseline) {
	for (GtkWidget *c = gtk_widget_get_first_child(w); c; c = gtk_widget_get_next_sibling(c))
		if (GTK_IS_POPOVER(c)) gtk_popover_present(GTK_POPOVER(c));
}

static void iris_view_dispose(GObject *o) {
	GtkWidget *c;
	while ((c = gtk_widget_get_first_child(GTK_WIDGET(o)))) gtk_widget_unparent(c);
	G_OBJECT_CLASS(iris_view_parent_class)->dispose(o);
}

static void iris_view_class_init(IrisViewClass *k) {
	GTK_WIDGET_CLASS(k)->snapshot = iris_view_snapshot;
	GTK_WIDGET_CLASS(k)->unrealize = iris_view_unrealize;
	GTK_WIDGET_CLASS(k)->size_allocate = iris_view_size_allocate;
	G_OBJECT_CLASS(k)->dispose = iris_view_dispose;
}

static void iris_view_init(IrisView *v) {}

// ---- frames ----

// After a frame: the page views move and the window acts (outside drawing,
// where GTK lets widgets change).
static gboolean afterFrame(gpointer d) {
	lgwGoAfter();
	return G_SOURCE_REMOVE;
}

static volatile int wanted; // a frame was asked for from any thread

static gboolean redraw(gpointer d) {
	__atomic_store_n(&wanted, 0, __ATOMIC_SEQ_CST);
	uiDirty = 1;
	if (view) gtk_widget_queue_draw(view);
	return G_SOURCE_REMOVE;
}

// lgwInvalidate asks for a frame of the interface; safe from any thread.
void lgwInvalidate(void) {
	if (__atomic_exchange_n(&wanted, 1, __ATOMIC_SEQ_CST) == 0) g_idle_add_full(G_PRIORITY_HIGH_IDLE, redraw, NULL, NULL);
}

void lgwAfterFrame(void) { g_idle_add_full(G_PRIORITY_DEFAULT, afterFrame, NULL, NULL); }

static void readScale(void) {
	if (!view) return;
	gint dpi = 0;
	g_object_get(gtk_settings_get_default(), "gtk-xft-dpi", &dpi, NULL);
	double text = dpi > 0 ? dpi / 1024.0 / 96.0 : 1;
	lgwGoScale(scaleOf(view), text);
}

static void onScale(GObject *o, GParamSpec *p, gpointer d) {
	readScale();
	lgwInvalidate();
}

static void onViewRealize(GtkWidget *w, gpointer d) {
	GtkNative *n = gtk_widget_get_native(w);
	GdkSurface *s = n ? gtk_native_get_surface(n) : NULL;
	if (s && g_object_class_find_property(G_OBJECT_GET_CLASS(s), "scale")) g_signal_connect(s, "notify::scale", G_CALLBACK(onScale), NULL);
	if (s) g_signal_connect(s, "notify::scale-factor", G_CALLBACK(onScale), NULL);
	if (s && GDK_IS_TOPLEVEL(s)) g_signal_connect(s, "notify::state", G_CALLBACK(onScale), NULL);
	gtk_im_context_set_client_widget(im, w);
	readScale();
}

// ---- input ----

// local turns an event's place on the window's surface into the view's units.
static void local(GdkEvent *e, double *x, double *y) {
	double ex = 0, ey = 0, ox, oy;
	gdk_event_get_position(e, &ex, &ey);
	origin(view, &ox, &oy);
	*x = ex - ox, *y = ey - oy;
}

static int touchOf(GdkEvent *e) {
	GdkDevice *d = gdk_event_get_device(e);
	GdkInputSource src = d ? gdk_device_get_source(d) : GDK_SOURCE_MOUSE;
	return src == GDK_SOURCE_TOUCHSCREEN || src == GDK_SOURCE_TOUCHPAD;
}

static int pressedOnUI; // a press went to the interface: its motion and release follow
static int onUI;        // the pointer is over the interface (not a page)

static gboolean onEvent(GtkEventControllerLegacy *c, GdkEvent *e, gpointer d) {
	GdkEventType t = gdk_event_get_event_type(e);
	guint state = gdk_event_get_modifier_state(e);
	double x, y;
	switch (t) {
	case GDK_BUTTON_PRESS:
	case GDK_BUTTON_RELEASE: {
		local(e, &x, &y);
		int press = t == GDK_BUTTON_PRESS;
		if (press) gtk_widget_grab_focus(view);
		if (!(pressedOnUI && !press) && lgxPagePointer && lgxPagePointer(e, x, y)) return TRUE;
		if (press) {
			pressedOnUI = 1;
			if (lgxUIFocus) lgxUIFocus();
		} else {
			pressedOnUI = 0;
		}
		guint button = gdk_button_event_get_button(e);
		GdkDevice *dev = gdk_event_get_device(e);
		int act = lgwGoButton(x, y, button, press, state, dev && gdk_device_get_source(dev) == GDK_SOURCE_TOUCHSCREEN);
		GdkSurface *s = gtk_native_get_surface(gtk_widget_get_native(view));
		if (act == 1 && s && GDK_IS_TOPLEVEL(s)) { // our title bar: the system moves the window (Wayland needs this)
			double ex, ey;
			gdk_event_get_position(e, &ex, &ey);
			pressedOnUI = 0;
			gdk_toplevel_begin_move(GDK_TOPLEVEL(s), gdk_event_get_device(e), button, ex, ey, gdk_event_get_time(e));
		} else if (act == 2 && s && GDK_IS_TOPLEVEL(s)) { // right click on the title bar: the system's window menu
			gdk_toplevel_show_window_menu(GDK_TOPLEVEL(s), e);
		}
		return TRUE;
	}
	case GDK_MOTION_NOTIFY:
		local(e, &x, &y);
		if (!pressedOnUI && lgxPagePointer && lgxPagePointer(e, x, y)) {
			if (onUI) lgwGoLeave(); // the pointer went onto a page
			onUI = 0;
			return TRUE;
		}
		onUI = 1;
		lgwGoMotion(x, y, state, gdk_event_get_device(e) && gdk_device_get_source(gdk_event_get_device(e)) == GDK_SOURCE_TOUCHSCREEN);
		return TRUE;
	case GDK_SCROLL: {
		local(e, &x, &y);
		if (lgxPagePointer && lgxPagePointer(e, x, y)) return TRUE;
		int touch = touchOf(e);
		if (p_scroll_unit) touch = p_scroll_unit(e) == GDK_SCROLL_UNIT_SURFACE;
		switch (gdk_scroll_event_get_direction(e)) {
		case GDK_SCROLL_UP: lgwGoScroll(0, -1, 0, state, 0); break;
		case GDK_SCROLL_DOWN: lgwGoScroll(0, 1, 0, state, 0); break;
		case GDK_SCROLL_LEFT: lgwGoScroll(-1, 0, 0, state, 0); break;
		case GDK_SCROLL_RIGHT: lgwGoScroll(1, 0, 0, state, 0); break;
		case GDK_SCROLL_SMOOTH: {
			double dx = 0, dy = 0;
			gdk_scroll_event_get_deltas(e, &dx, &dy);
			if (touch) dx /= 10, dy /= 10; // a touchpad's deltas are in pixels, a wheel's in notches
			lgwGoScroll(dx, dy, 1, state, touch);
			break;
		}
		}
		return TRUE;
	}
	case GDK_TOUCHPAD_PINCH: {
		local(e, &x, &y);
		GdkTouchpadGesturePhase ph = gdk_touchpad_event_get_gesture_phase(e);
		int phase = ph == GDK_TOUCHPAD_GESTURE_PHASE_BEGIN ? 0 : ph == GDK_TOUCHPAD_GESTURE_PHASE_UPDATE ? 1 : 2;
		lgwGoPinch(phase, gdk_touchpad_event_get_pinch_scale(e), x, y);
		return TRUE;
	}
	case GDK_LEAVE_NOTIFY:
		if (gdk_crossing_event_get_mode(e) == GDK_CROSSING_NORMAL) {
			lgwGoLeave();
			onUI = 0;
			if (lgxPagesLeave) lgxPagesLeave();
		}
		return FALSE;
	case GDK_KEY_PRESS:
	case GDK_KEY_RELEASE: {
		if (lgxPageKey && lgxPageKey(e)) return TRUE;
		if (t == GDK_KEY_PRESS && lgwGoKey(gdk_key_event_get_keyval(e), state)) return TRUE; // shortcuts and editing keys
		return gtk_im_context_filter_keypress(im, e);
	}
	default:
		return FALSE;
	}
}

static void onCommit(GtkIMContext *c, char *s, gpointer d) { lgwGoText(s); }
static void onFocusIn(GtkEventControllerFocus *c, gpointer d) { gtk_im_context_focus_in(im); }
static void onFocusOut(GtkEventControllerFocus *c, gpointer d) { gtk_im_context_focus_out(im); }

// ---- the window's state ----

static void sendState(void) {
	if (!win) return;
	int ww = 0, wh = 0;
	gtk_window_get_default_size(GTK_WINDOW(win), &ww, &wh);
	int maxed = gtk_window_is_maximized(GTK_WINDOW(win)), full = gtk_window_is_fullscreen(GTK_WINDOW(win));
	GdkSurface *s = gtk_native_get_surface(GTK_NATIVE(win));
	int tiled = s && GDK_IS_TOPLEVEL(s) && (gdk_toplevel_get_state(GDK_TOPLEVEL(s)) & GDK_TOPLEVEL_STATE_TILED);
	if (!maxed && !full && tiled) return; // a tiling layout's size is not the reader's choice
	lgwGoState(maxed, full, ww, wh);
}

static void onWinState(GObject *o, GParamSpec *p, gpointer d) { sendState(); }

// lgwSendState tells the interface the window's state again (it may have
// changed before the interface existed).
void lgwSendState(void) { sendState(); }

// The system's close (Alt+F4, the dock): Iris closes its tabs first.
static gboolean onCloseRequest(GtkWindow *w, gpointer d) {
	lgwGoClose();
	return TRUE;
}

static void onDestroy(GtkWidget *w, gpointer d) {
	win = view = NULL;
	if (im) g_object_unref(im);
	im = NULL;
	lgwGoDestroy();
}

// ---- clipboard ----

static GdkClipboard *clipboard(void) { return gdk_display_get_clipboard(gdk_display_get_default()); }

void lgwSetClipboard(const char *s) { gdk_clipboard_set_text(clipboard(), s); }

static void pasted(GObject *o, GAsyncResult *r, gpointer d) {
	char *text = gdk_clipboard_read_text_finish(GDK_CLIPBOARD(o), r, NULL);
	if (text) lgwGoPaste(text);
	g_free(text);
}

void lgwPaste(void) { gdk_clipboard_read_text_async(clipboard(), NULL, pasted, NULL); }

// ---- window actions ----

void lgwMinimize(void) {
	if (win) gtk_window_minimize(GTK_WINDOW(win));
}
void lgwToggleMaximize(void) {
	if (!win) return;
	if (gtk_window_is_maximized(GTK_WINDOW(win))) gtk_window_unmaximize(GTK_WINDOW(win));
	else gtk_window_maximize(GTK_WINDOW(win));
}
void lgwFullscreen(int on) {
	if (!win) return;
	if (on) gtk_window_fullscreen(GTK_WINDOW(win));
	else gtk_window_unfullscreen(GTK_WINDOW(win));
}
void lgwClose(void) {
	if (win) gtk_window_destroy(GTK_WINDOW(win));
}
void lgwPresent(void) {
	if (win) gtk_window_present(GTK_WINDOW(win));
}
void lgwFocus(void) {
	if (view) gtk_widget_grab_focus(view);
	if (lgxUIFocus) lgxUIFocus();
}

// ---- the tests' picture of the whole window (LITEGO_SHOT) ----

static gboolean windowShot(gpointer d) {
	const char *pre = g_getenv("LITEGO_SHOT");
	GtkNative *n = view ? gtk_widget_get_native(view) : NULL;
	GskRenderer *r = n ? gtk_native_get_renderer(n) : NULL;
	int W = view ? gtk_widget_get_width(view) : 0, H = view ? gtk_widget_get_height(view) : 0;
	if (!pre || !r || W <= 0 || H <= 0) return G_SOURCE_REMOVE;
	double s = scaleOf(view);
	GdkPaintable *p = gtk_widget_paintable_new(view);
	GtkSnapshot *sn = gtk_snapshot_new();
	gtk_snapshot_scale(sn, (float)s, (float)s);
	gdk_paintable_snapshot(p, GDK_SNAPSHOT(sn), W, H);
	GskRenderNode *node = gtk_snapshot_free_to_node(sn);
	if (node) {
		GdkTexture *t = gsk_renderer_render_texture(r, node, &GRAPHENE_RECT_INIT(0, 0, (float)ceil(W * s), (float)ceil(H * s)));
		char *path = g_strdup_printf("%s-window.png", pre);
		if (t && gdk_texture_save_to_png(t, path))
			g_printerr("Iris: window written to %s (%dx%d at scale %.2f)\n", path, gdk_texture_get_width(t), gdk_texture_get_height(t), s);
		g_free(path);
		if (t) g_object_unref(t);
		gsk_render_node_unref(node);
	}
	g_object_unref(p);
	return G_SOURCE_REMOVE;
}

// ---- running Go on the GTK thread ----

static gboolean doGo(gpointer h) {
	lgwGoDo((uintptr_t)h);
	return G_SOURCE_REMOVE;
}

void lgwDo(uintptr_t h) { g_idle_add_full(G_PRIORITY_DEFAULT, doGo, (gpointer)h, NULL); }

// ---- startup ----

// appID is the Wayland app id and icon name: the Flatpak's id inside a
// Flatpak (its desktop file and icon carry that name), lite-go otherwise.
static const char *appID(void) {
	const char *id = g_getenv("FLATPAK_ID");
	return id && *id ? id : "lite-go";
}

void lgwInit(void) {
	loadSyms();
	// GTK's OpenGL renderer: Iris's interface is a GL texture, which it
	// takes as it is (GSK_RENDERER set by hand wins)
	g_setenv("GSK_RENDERER", "ngl", FALSE);
	g_set_prgname(appID()); // the Wayland app id: matches the desktop file, for the dock icon
	g_set_application_name("Iris");
	gtk_init();
}

static GMainLoop *loop;

void lgwMain(void) {
	loop = g_main_loop_new(NULL, FALSE);
	g_main_loop_run(loop);
}

// lgwOpen makes the window and returns the view the pages are drawn in.
uintptr_t lgwOpen(int w, int h, int maximized) {
	win = gtk_window_new();
	gtk_window_set_title(GTK_WINDOW(win), "Iris");
	gtk_window_set_icon_name(GTK_WINDOW(win), appID());
	gtk_window_set_default_size(GTK_WINDOW(win), w, h);
	// client-side decorations with no visible title bar: our own title row
	// is drawn by the interface; GTK keeps the shadow and the resize edges
	GtkWidget *bar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
	gtk_widget_set_size_request(bar, -1, 0);
	gtk_window_set_titlebar(GTK_WINDOW(win), bar);
	GtkCssProvider *css = gtk_css_provider_new();
	G_GNUC_BEGIN_IGNORE_DEPRECATIONS
	gtk_css_provider_load_from_data(css,
	                                "window.csd > .titlebar:not(headerbar){padding:0;margin:0;min-height:0;background:none;border:none;box-shadow:none;}"
	                                "window{background:#121214;}",
	                                -1);
	G_GNUC_END_IGNORE_DEPRECATIONS
	gtk_style_context_add_provider_for_display(gdk_display_get_default(), GTK_STYLE_PROVIDER(css), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
	g_object_unref(css);

	view = g_object_new(iris_view_get_type(), NULL);
	gtk_widget_set_focusable(view, TRUE);
	gtk_widget_set_hexpand(view, TRUE);
	gtk_widget_set_vexpand(view, TRUE);
	gtk_widget_set_size_request(view, 480, 420);
	im = gtk_im_multicontext_new();
	g_signal_connect(im, "commit", G_CALLBACK(onCommit), NULL);
	g_signal_connect(view, "realize", G_CALLBACK(onViewRealize), NULL);
	GtkEventController *legacy = gtk_event_controller_legacy_new();
	g_signal_connect(legacy, "event", G_CALLBACK(onEvent), NULL);
	gtk_widget_add_controller(view, legacy);
	GtkEventController *focus = gtk_event_controller_focus_new();
	g_signal_connect(focus, "enter", G_CALLBACK(onFocusIn), NULL);
	g_signal_connect(focus, "leave", G_CALLBACK(onFocusOut), NULL);
	gtk_widget_add_controller(view, focus);
	gtk_window_set_child(GTK_WINDOW(win), view);

	g_signal_connect(win, "notify::maximized", G_CALLBACK(onWinState), NULL);
	g_signal_connect(win, "notify::fullscreened", G_CALLBACK(onWinState), NULL);
	g_signal_connect(win, "notify::default-width", G_CALLBACK(onWinState), NULL);
	g_signal_connect(win, "notify::default-height", G_CALLBACK(onWinState), NULL);
	g_signal_connect(win, "close-request", G_CALLBACK(onCloseRequest), NULL);
	g_signal_connect(win, "destroy", G_CALLBACK(onDestroy), NULL);
	g_signal_connect(gtk_settings_get_default(), "notify::gtk-xft-dpi", G_CALLBACK(onScale), NULL);
	if (maximized) gtk_window_maximize(GTK_WINDOW(win));
	gtk_window_present(GTK_WINDOW(win));
	gtk_widget_grab_focus(view);
	if (g_getenv("LITEGO_SHOT")) g_timeout_add_seconds(14, windowShot, NULL);
	return (uintptr_t)view;
}

int lgwWayland(void) {
	const char *n = G_OBJECT_TYPE_NAME(gdk_display_get_default());
	return n && strstr(n, "Wayland") != NULL;
}
