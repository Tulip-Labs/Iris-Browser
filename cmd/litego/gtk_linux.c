//go:build linux && webkit

// The Linux window of Lite Go, made with GTK so that it runs natively on
// Wayland (GNOME, KDE and the rest) as well as on X11.
//
// GTK owns the window. Inside it a GtkLayout holds, from the bottom up:
//   - a GtkGLArea where Gio's GPU renderer draws our interface (the same
//     drawing as on Windows and macOS), under an input-only GtkEventBox that
//     takes the pointer and keyboard;
//   - the WebKitWebView of each page, placed over it where the page goes.
// One window, one connection to the display: nothing is embedded across
// programs, which is what Wayland does not allow.
//
// The window draws its own title bar (ours). Client-side decorations with an
// empty GTK title bar keep the system's shadow, rounded corners and resize
// edges, so it looks and behaves like a GNOME app.

#include <epoxy/gl.h>
#include <gtk/gtk.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

extern void lgwGoRender(int w, int h, int sf, unsigned int fbo);
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
extern void lgwGoScale(int sf, double text);

static GtkWidget *win, *layout, *area, *events;
static GtkIMContext *im;
static volatile int wanted; // a render was asked for from any thread

// Rendering

static gboolean onRender(GtkGLArea *a, GdkGLContext *c, gpointer d) {
	GLint fbo = 0;
	glGetIntegerv(GL_FRAMEBUFFER_BINDING, &fbo);
	int sf = gtk_widget_get_scale_factor(GTK_WIDGET(a));
	int w = gtk_widget_get_allocated_width(GTK_WIDGET(a)) * sf, h = gtk_widget_get_allocated_height(GTK_WIDGET(a)) * sf;
	lgwGoRender(w, h, sf, (unsigned int)fbo);
	return TRUE;
}

// After a frame: the page views move and the window acts (outside drawing,
// where GTK lets widgets change).
static gboolean afterFrame(gpointer d) {
	lgwGoAfter();
	return G_SOURCE_REMOVE;
}

static gboolean redraw(gpointer d) {
	__atomic_store_n(&wanted, 0, __ATOMIC_SEQ_CST);
	if (area) gtk_gl_area_queue_render(GTK_GL_AREA(area));
	return G_SOURCE_REMOVE;
}

// lgwInvalidate asks for a frame; safe from any thread.
void lgwInvalidate(void) {
	if (__atomic_exchange_n(&wanted, 1, __ATOMIC_SEQ_CST) == 0) g_idle_add_full(G_PRIORITY_HIGH_IDLE, redraw, NULL, NULL);
}

void lgwAfterFrame(void) { g_idle_add_full(G_PRIORITY_DEFAULT, afterFrame, NULL, NULL); }

static void onRealize(GtkGLArea *a, gpointer d) {
	gtk_gl_area_make_current(a);
}

static void onUnrealize(GtkGLArea *a, gpointer d) {
	gtk_gl_area_make_current(a);
	if (!gtk_gl_area_get_error(a)) lgwGoUnrealize();
}

// The GL area always fills the layout (a GtkLayout gives its children their
// requested size, and asks for none itself, so the window can still shrink).
static void onLayoutSize(GtkWidget *l, GdkRectangle *r, gpointer d) {
	int w, h;
	gtk_widget_get_size_request(area, &w, &h);
	if (w != r->width || h != r->height) {
		gtk_widget_set_size_request(area, r->width, r->height);
		gtk_widget_set_size_request(events, r->width, r->height);
	}
}

static void readScale(void) {
	int sf = gtk_widget_get_scale_factor(win);
	gint dpi = 0;
	g_object_get(gtk_settings_get_default(), "gtk-xft-dpi", &dpi, NULL);
	double text = dpi > 0 ? dpi / 1024.0 / 96.0 : 1;
	lgwGoScale(sf, text);
}

static void onScale(GObject *o, GParamSpec *p, gpointer d) {
	readScale();
	lgwInvalidate();
}

// Input

static gboolean onButton(GtkWidget *w, GdkEventButton *e, gpointer d) {
	if (e->type == GDK_2BUTTON_PRESS || e->type == GDK_3BUTTON_PRESS) return TRUE; // we count clicks ourselves
	int press = e->type == GDK_BUTTON_PRESS;
	if (press) gtk_widget_grab_focus(events);
	GdkDevice *dev = gdk_event_get_source_device((GdkEvent *)e);
	int touch = dev && gdk_device_get_source(dev) == GDK_SOURCE_TOUCHSCREEN;
	int act = lgwGoButton(e->x, e->y, e->button, press, e->state, touch);
	if (act == 1) // our title bar: the system moves the window (Wayland needs this)
		gtk_window_begin_move_drag(GTK_WINDOW(win), e->button, (int)e->x_root, (int)e->y_root, e->time);
	else if (act == 2) // right click on the title bar: the system's window menu
		gdk_window_show_window_menu(gtk_widget_get_window(win), (GdkEvent *)e);
	return TRUE;
}

static gboolean onMotion(GtkWidget *w, GdkEventMotion *e, gpointer d) {
	GdkDevice *dev = gdk_event_get_source_device((GdkEvent *)e);
	lgwGoMotion(e->x, e->y, e->state, dev && gdk_device_get_source(dev) == GDK_SOURCE_TOUCHSCREEN);
	return TRUE;
}

static gboolean onLeave(GtkWidget *w, GdkEventCrossing *e, gpointer d) {
	if (e->mode == GDK_CROSSING_NORMAL) lgwGoLeave();
	return FALSE;
}

static gboolean onScroll(GtkWidget *w, GdkEventScroll *e, gpointer d) {
	GdkDevice *dev = gdk_event_get_source_device((GdkEvent *)e);
	int touch = dev && (gdk_device_get_source(dev) == GDK_SOURCE_TOUCHPAD || gdk_device_get_source(dev) == GDK_SOURCE_TOUCHSCREEN);
	switch (e->direction) {
	case GDK_SCROLL_UP: lgwGoScroll(0, -1, 0, e->state, 0); break;
	case GDK_SCROLL_DOWN: lgwGoScroll(0, 1, 0, e->state, 0); break;
	case GDK_SCROLL_LEFT: lgwGoScroll(-1, 0, 0, e->state, 0); break;
	case GDK_SCROLL_RIGHT: lgwGoScroll(1, 0, 0, e->state, 0); break;
	case GDK_SCROLL_SMOOTH: lgwGoScroll(e->delta_x, e->delta_y, 1, e->state, touch); break;
	}
	return TRUE;
}

static gboolean onTouchpad(GtkWidget *w, GdkEvent *e, gpointer d) {
	if (e->type != GDK_TOUCHPAD_PINCH) return FALSE;
	GdkEventTouchpadPinch *p = &e->touchpad_pinch;
	int phase = p->phase == GDK_TOUCHPAD_GESTURE_PHASE_BEGIN ? 0 : p->phase == GDK_TOUCHPAD_GESTURE_PHASE_UPDATE ? 1 : 2;
	lgwGoPinch(phase, p->scale, p->x, p->y);
	return TRUE;
}

static gboolean onKey(GtkWidget *w, GdkEventKey *e, gpointer d) {
	if (e->type == GDK_KEY_PRESS && lgwGoKey(e->keyval, e->state)) return TRUE; // shortcuts and editing keys
	return gtk_im_context_filter_keypress(im, e);
}

static void onCommit(GtkIMContext *c, char *s, gpointer d) { lgwGoText(s); }

static gboolean onFocusIn(GtkWidget *w, GdkEventFocus *e, gpointer d) {
	gtk_im_context_focus_in(im);
	return FALSE;
}

static gboolean onFocusOut(GtkWidget *w, GdkEventFocus *e, gpointer d) {
	gtk_im_context_focus_out(im);
	return FALSE;
}

static void onEventsRealize(GtkWidget *w, gpointer d) { gtk_im_context_set_client_window(im, gtk_widget_get_window(w)); }

static gboolean onState(GtkWidget *w, GdkEventWindowState *e, gpointer d) {
	GdkWindowState s = e->new_window_state;
	int ww = 0, wh = 0;
	gtk_window_get_size(GTK_WINDOW(win), &ww, &wh);
	lgwGoState((s & GDK_WINDOW_STATE_MAXIMIZED) != 0, (s & GDK_WINDOW_STATE_FULLSCREEN) != 0, ww, wh);
	return FALSE;
}

// The reader resized the window: the size is kept for next time.
static gboolean onConfigure(GtkWidget *w, GdkEvent *e, gpointer d) {
	GdkWindow *gw = gtk_widget_get_window(win);
	if (!gw) return FALSE;
	GdkWindowState s = gdk_window_get_state(gw);
	if (s & (GDK_WINDOW_STATE_MAXIMIZED | GDK_WINDOW_STATE_FULLSCREEN | GDK_WINDOW_STATE_TILED | GDK_WINDOW_STATE_ICONIFIED)) return FALSE;
	int ww = 0, wh = 0;
	gtk_window_get_size(GTK_WINDOW(win), &ww, &wh);
	lgwGoState(0, 0, ww, wh);
	return FALSE;
}

// The system's close (Alt+F4, the dock): Lite Go closes its tabs first.
static gboolean onDelete(GtkWidget *w, GdkEvent *e, gpointer d) {
	lgwGoClose();
	return TRUE;
}

static void onDestroy(GtkWidget *w, gpointer d) {
	win = layout = area = events = NULL;
	if (im) g_object_unref(im);
	im = NULL;
	lgwGoDestroy();
}

// Clipboard

void lgwSetClipboard(const char *s) { gtk_clipboard_set_text(gtk_clipboard_get(GDK_SELECTION_CLIPBOARD), s, -1); }

static void pasted(GtkClipboard *c, const gchar *text, gpointer d) {
	if (text) lgwGoPaste((char *)text);
}

void lgwPaste(void) { gtk_clipboard_request_text(gtk_clipboard_get(GDK_SELECTION_CLIPBOARD), pasted, NULL); }

// Window actions

void lgwMinimize(void) {
	if (win) gtk_window_iconify(GTK_WINDOW(win));
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
	if (win) gtk_widget_destroy(win);
}
void lgwPresent(void) {
	if (win) gtk_window_present(GTK_WINDOW(win));
}
void lgwFocus(void) {
	if (events) gtk_widget_grab_focus(events);
}

// Running Go on the GTK thread

static gboolean doGo(gpointer h) {
	lgwGoDo((uintptr_t)h);
	return G_SOURCE_REMOVE;
}

void lgwDo(uintptr_t h) { g_idle_add_full(G_PRIORITY_DEFAULT, doGo, (gpointer)h, NULL); }

// Startup

// appID is the Wayland app id and icon name: the Flatpak's id inside a
// Flatpak (its desktop file and icon carry that name), lite-go otherwise.
static const char *appID(void) {
	const char *id = g_getenv("FLATPAK_ID");
	return id && *id ? id : "lite-go";
}

void lgwInit(void) {
	// GTK picks the session's own display server: Wayland where there is one
	gtk_init(NULL, NULL);
	g_object_set(gtk_settings_get_default(), "gtk-application-prefer-dark-theme", FALSE, NULL);
	g_set_prgname(appID()); // the Wayland app id: matches the desktop file, for the dock icon
	g_set_application_name("Lite Go");
}

void lgwMain(void) { gtk_main(); }

// lgwOpen makes the window and returns the layout the pages go in.
uintptr_t lgwOpen(int w, int h, int maximized) {
	win = gtk_window_new(GTK_WINDOW_TOPLEVEL);
	gtk_window_set_title(GTK_WINDOW(win), "Lite Go");
	gtk_window_set_icon_name(GTK_WINDOW(win), appID());
	gtk_window_set_default_size(GTK_WINDOW(win), w, h);
	GdkGeometry g = {.min_width = 480, .min_height = 420};
	gtk_window_set_geometry_hints(GTK_WINDOW(win), NULL, &g, GDK_HINT_MIN_SIZE);
	// client-side decorations with no visible title bar: our own title row
	// is drawn by the interface; GTK keeps the shadow and the resize edges
	GtkWidget *bar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
	gtk_widget_set_size_request(bar, -1, 0);
	gtk_window_set_titlebar(GTK_WINDOW(win), bar);
	gtk_widget_show(bar);
	GtkCssProvider *css = gtk_css_provider_new();
	gtk_css_provider_load_from_data(css,
	                                "window.csd > .titlebar:not(headerbar){padding:0;margin:0;min-height:0;background:none;border:none;box-shadow:none;}",
	                                -1, NULL);
	gtk_style_context_add_provider_for_screen(gdk_screen_get_default(), GTK_STYLE_PROVIDER(css), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
	g_object_unref(css);

	layout = gtk_layout_new(NULL, NULL);
	g_signal_connect(layout, "size-allocate", G_CALLBACK(onLayoutSize), NULL);

	area = gtk_gl_area_new();
	gtk_gl_area_set_has_alpha(GTK_GL_AREA(area), FALSE);
	gtk_gl_area_set_auto_render(GTK_GL_AREA(area), FALSE);
	g_signal_connect(area, "render", G_CALLBACK(onRender), NULL);
	g_signal_connect(area, "realize", G_CALLBACK(onRealize), NULL);
	g_signal_connect(area, "unrealize", G_CALLBACK(onUnrealize), NULL);
	gtk_layout_put(GTK_LAYOUT(layout), area, 0, 0);

	// an input-only box over the GL area: pointer, wheel, touchpad and keys
	events = gtk_event_box_new();
	gtk_event_box_set_visible_window(GTK_EVENT_BOX(events), FALSE);
	gtk_widget_set_can_focus(events, TRUE);
	gtk_widget_add_events(events, GDK_POINTER_MOTION_MASK | GDK_BUTTON_PRESS_MASK | GDK_BUTTON_RELEASE_MASK | GDK_SCROLL_MASK |
	                                  GDK_SMOOTH_SCROLL_MASK | GDK_LEAVE_NOTIFY_MASK | GDK_KEY_PRESS_MASK | GDK_KEY_RELEASE_MASK |
	                                  GDK_FOCUS_CHANGE_MASK | GDK_TOUCHPAD_GESTURE_MASK);
	g_signal_connect(events, "button-press-event", G_CALLBACK(onButton), NULL);
	g_signal_connect(events, "button-release-event", G_CALLBACK(onButton), NULL);
	g_signal_connect(events, "motion-notify-event", G_CALLBACK(onMotion), NULL);
	g_signal_connect(events, "leave-notify-event", G_CALLBACK(onLeave), NULL);
	g_signal_connect(events, "scroll-event", G_CALLBACK(onScroll), NULL);
	g_signal_connect(events, "event", G_CALLBACK(onTouchpad), NULL);
	g_signal_connect(events, "key-press-event", G_CALLBACK(onKey), NULL);
	g_signal_connect(events, "key-release-event", G_CALLBACK(onKey), NULL);
	g_signal_connect(events, "focus-in-event", G_CALLBACK(onFocusIn), NULL);
	g_signal_connect(events, "focus-out-event", G_CALLBACK(onFocusOut), NULL);
	g_signal_connect(events, "realize", G_CALLBACK(onEventsRealize), NULL);
	gtk_layout_put(GTK_LAYOUT(layout), events, 0, 0);

	im = gtk_im_multicontext_new();
	g_signal_connect(im, "commit", G_CALLBACK(onCommit), NULL);

	gtk_container_add(GTK_CONTAINER(win), layout);
	g_signal_connect(win, "window-state-event", G_CALLBACK(onState), NULL);
	g_signal_connect(win, "configure-event", G_CALLBACK(onConfigure), NULL);
	g_signal_connect(win, "delete-event", G_CALLBACK(onDelete), NULL);
	g_signal_connect(win, "destroy", G_CALLBACK(onDestroy), NULL);
	g_signal_connect(win, "notify::scale-factor", G_CALLBACK(onScale), NULL);
	g_signal_connect(gtk_settings_get_default(), "notify::gtk-xft-dpi", G_CALLBACK(onScale), NULL);
	readScale();
	if (maximized) gtk_window_maximize(GTK_WINDOW(win));
	gtk_widget_show_all(win);
	gtk_widget_grab_focus(events);
	return (uintptr_t)layout;
}

int lgwWayland(void) {
	const char *n = G_OBJECT_TYPE_NAME(gdk_display_get_default());
	return n && strstr(n, "Wayland") != NULL;
}
