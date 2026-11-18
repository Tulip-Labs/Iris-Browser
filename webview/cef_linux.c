//go:build linux && webkit

// The Linux side of Iris's web engine on Chromium, through CEF (the
// Chromium Embedded Framework).
//
// Iris's window is a GTK 4 window (cmd/iris/gtk_linux.c) with one view:
// the interface is drawn there by Gio, and each page over it. CEF renders the
// pages off screen ("windowless") at the window's exact scale: it hands over
// the pixels of each page, this file turns them into textures the view draws
// (lgxSnapshotPages), and passes the pointer, wheel and keys back. Nothing
// here needs X11: it runs on Wayland (and on X11 too).
//
// It speaks the same small protocol to Go as the WebKitGTK engine
// (webview_linux.c): lgxCall with an operation, and lgxGo* callbacks. CEF's
// UI thread is GTK's main thread (an external message pump), so everything
// here runs there, except the resource checks, which CEF makes on its IO
// thread (views are found under a lock).

#define _GNU_SOURCE // RTLD_DEFAULT
#include <dlfcn.h>
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

enum { OP_NEW = 1, OP_NAV, OP_BACK, OP_FWD, OP_RELOAD, OP_STOP, OP_BOUNDS, OP_SHOW, OP_FOCUS, OP_EVAL, OP_MUTE, OP_CLOSE, OP_SCRIPT, OP_PROFILE, OP_PRIVATE, OP_BLOCKLIST, OP_ZOOM, OP_DLCANCEL, OP_SCHEME };

extern void lgxGoCreated(uintptr_t cb, int ok);
extern void lgxGoURL(uintptr_t id, char *u);
extern void lgxGoTitle(uintptr_t id, char *t);
extern void lgxGoLoading(uintptr_t id, int on, int back, int fwd);
extern char *lgxGoDecide(uintptr_t id, char *u, int gesture);
extern uintptr_t lgxGoPopup(uintptr_t id, char *u);
extern void lgxGoFullscreen(uintptr_t id, int on);
extern void lgxGoCrashed(uintptr_t id);
extern void lgxGoOpenTab(uintptr_t id, char *u);
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
	GdkTexture *tex, *popTex; // the last frames (the page's, a select box's), ready for the screen
	cairo_surface_t *page;    // the last frame on the processor, for the tests' pictures (IRIS_SHOT)
	cef_rect_t popupRect;
	int popupShown;
	int px[4];     // where the page is in the view, in real pixels: x, y, width, height
	int w, h;      // its size in GTK units (Chromium's)
	double scale;  // the scale Chromium was last told
	const char *cursor; // the pointer's shape over the page
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

static GtkWidget *host; // the window's view
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

#if !GTK_CHECK_VERSION(4, 8, 0)
typedef enum { GDK_SCROLL_UNIT_WHEEL, GDK_SCROLL_UNIT_SURFACE } GdkScrollUnit;
#endif
typedef struct _GdkMemoryTextureBuilder MemBuilder;
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
static double (*p_monitor_get_scale)(GdkMonitor *);
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
	SYM(p_monitor_get_scale, "gdk_monitor_get_scale");
	SYM(p_append_scaled, "gtk_snapshot_append_scaled_texture");
	SYM(p_scroll_unit, "gdk_scroll_event_get_unit");
#undef SYM
	if (!p_mtb_new || !p_mtb_set_bytes || !p_mtb_set_stride || !p_mtb_set_width || !p_mtb_set_height || !p_mtb_set_format ||
	    !p_mtb_set_update_texture || !p_mtb_set_update_region || !p_mtb_build)
		p_mtb_new = NULL;
}

// scaleOf is the window's scale: real pixels per GTK unit, fractional where
// the system draws fractionally (1.25, 1.5…).
static double scaleOf(void) {
	loadSyms();
	GtkNative *n = host ? gtk_widget_get_native(host) : NULL;
	GdkSurface *s = n ? gtk_native_get_surface(n) : NULL;
	if (!s) return host ? gtk_widget_get_scale_factor(host) : 1;
	double sc = p_surface_get_scale ? p_surface_get_scale(s) : gdk_surface_get_scale_factor(s);
	return sc > 0.25 ? sc : 1;
}

// pageDSF is the scale Chromium draws pages at: the window's own, read once
// it has settled (startWhenSettled) and given to Chromium at its start, the
// one time it takes one. dsf is that, or the window's until then.
static double pageDSF;
static double dsf(void) { return pageDSF > 0 ? pageDSF : scaleOf(); }

// Chromium's start, held until the window's scale settles (startWhenSettled)
static char *startDir;
static gint64 startAt, scaleSince;
static double lastScale;
static int cefStarting;           // setup ran
static GQueue early = G_QUEUE_INIT; // what the interface asked of the pages before it

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
	if (g_getenv("IRIS_NO_SANDBOX")) return 1;
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
	// Wayland, always (Iris's window is a Wayland window)
	setStr(&k, "ozone-platform");
	setStr(&val, g_getenv("WAYLAND_DISPLAY") || !g_getenv("DISPLAY") ? "wayland" : "x11");
	cl->append_switch_with_value(cl, &k, &val);
	cef_string_clear(&k);
	cef_string_clear(&val);
	// Chromium draws at exactly the window's scale, fractional ones (1.25,
	// 1.5) included: one page pixel on one screen pixel, sharp. Off screen it
	// takes the scale only from this switch (it ignores the pages' screen
	// information), so Chromium starts once the window's scale has settled
	// (startWhenSettled): the first one GTK reports is a guess the compositor
	// corrects a frame later (2, then 1.25).
	char sfs[16];
	g_ascii_formatd(sfs, sizeof sfs, "%.4g", pageDSF > 0 ? pageDSF : 1);
	setStr(&k, "force-device-scale-factor");
	setStr(&val, g_getenv("IRIS_SCALE") ? g_getenv("IRIS_SCALE") : sfs);
	cl->append_switch_with_value(cl, &k, &val);
	cef_string_clear(&k);
	cef_string_clear(&val);
	// GTK 4, as Iris's window: Chromium loads GTK itself (file pickers,
	// printing) and would take GTK 3 first, which cannot live beside GTK 4
	setStr(&k, "gtk-version");
	setStr(&val, "4");
	cl->append_switch_with_value(cl, &k, &val);
	cef_string_clear(&k);
	cef_string_clear(&val);
	// videos decoded on the graphics chip (VA-API) when there is one: far
	// less processor for YouTube and the like
	if (!g_getenv("LIBGL_ALWAYS_SOFTWARE") && access("/dev/dri/renderD128", R_OK | W_OK) == 0 &&
	    !(g_getenv("IRIS_GPU") && strcmp(g_getenv("IRIS_GPU"), "0") == 0)) {
		setStr(&k, "enable-features");
		setStr(&val, "AcceleratedVideoDecodeLinuxGL,AcceleratedVideoDecodeLinuxZeroCopyGL,AcceleratedVideoEncoder");
		cl->append_switch_with_value(cl, &k, &val);
		cef_string_clear(&k);
		cef_string_clear(&val);
	}
	// media keys and the like belong to the desktop, not to the pages
	setStr(&k, "disable-features");
	setStr(&val, "HardwareMediaKeyHandling,MediaSessionService,BackForwardCache,Translate,OptimizationHints,MediaRouter,"
	             "DialMediaRouteProvider,AutofillServerCommunication,CertificateTransparencyComponentUpdater,InterestFeedContentSuggestions,"
	             "IsolateOrigins,site-per-process,SpareRendererForSitePerProcess,PrefetchPrivacyChanges,Prerender2,LensOverlay,"
	             "GlobalMediaControls,PrivacySandboxSettings4,FedCm,LocalNetworkAccessChecks,PrivateNetworkAccessForWorkers,"
	             "PrivateNetworkAccessRespectPreflightResults,BlockInsecurePrivateNetworkRequests");
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
	const char *extra = g_getenv("IRIS_CEF_ARGS"); // for diagnosis: --name or --name=value, separated by spaces
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
//
// Each page's frames become a texture that the window's view draws over
// the interface (lgxSnapshotPages), on whole pixels of the screen. Chromium
// draws at the screen's exact scale, so one page pixel is one screen pixel:
// sharp at 1.25 or 1.5 as at 1 or 2, and never larger than the screen needs.
// Only the parts of a frame that changed go to the graphics chip again
// (GTK 4.16 and later; older ones take the whole frame).

// frameTexture makes a texture of a frame Chromium handed over (BGRA,
// premultiplied); with old, the texture it replaces, only the changed parts
// are uploaded.
static GdkTexture *frameTexture(GdkTexture *old, const void *buf, int w, int h, size_t n, const cef_rect_t *dirty) {
	GBytes *bytes = g_bytes_new(buf, (gsize)w * h * 4);
	GdkTexture *t;
	if (p_mtb_new) {
		MemBuilder *b = p_mtb_new();
		p_mtb_set_bytes(b, bytes);
		p_mtb_set_stride(b, (gsize)w * 4);
		p_mtb_set_width(b, w);
		p_mtb_set_height(b, h);
		p_mtb_set_format(b, GDK_MEMORY_B8G8R8A8_PREMULTIPLIED);
		if (old && gdk_texture_get_width(old) == w && gdk_texture_get_height(old) == h && n > 0 && dirty) {
			cairo_region_t *r = cairo_region_create();
			for (size_t i = 0; i < n; i++) {
				cairo_rectangle_int_t c = {dirty[i].x, dirty[i].y, dirty[i].width, dirty[i].height};
				cairo_region_union_rectangle(r, &c);
			}
			cairo_rectangle_int_t all = {0, 0, w, h};
			cairo_region_intersect_rectangle(r, &all);
			p_mtb_set_update_texture(b, old);
			p_mtb_set_update_region(b, r);
			cairo_region_destroy(r);
		}
		t = p_mtb_build(b);
		g_object_unref(b);
	} else {
		t = gdk_memory_texture_new(w, h, GDK_MEMORY_B8G8R8A8_PREMULTIPLIED, bytes, (gsize)w * 4);
	}
	g_bytes_unref(bytes);
	return t;
}

// copyInto copies a frame for the tests' page pictures (IRIS_SHOT).
static void copyInto(cairo_surface_t **dst, const void *buf, int w, int h) {
	if (!*dst || cairo_image_surface_get_width(*dst) != w || cairo_image_surface_get_height(*dst) != h) {
		if (*dst) cairo_surface_destroy(*dst);
		*dst = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h);
	}
	cairo_surface_flush(*dst);
	unsigned char *d = cairo_image_surface_get_data(*dst);
	int stride = cairo_image_surface_get_stride(*dst);
	for (int y = 0; y < h; y++) memcpy(d + (size_t)y * stride, (const unsigned char *)buf + (size_t)y * w * 4, (size_t)w * 4);
	cairo_surface_mark_dirty(*dst);
}

static void redrawView(void) {
	if (host) gtk_widget_queue_draw(host);
}

static void CEF_CALLBACK onPaint(cef_render_handler_t *self, cef_browser_t *b, cef_paint_element_type_t type, size_t n, cef_rect_t const *dirty,
                                 const void *buf, int w, int h) {
	LV *v = of(b);
	if (!v || w <= 0 || h <= 0) return;
	if (type == PET_POPUP) {
		GdkTexture *t = frameTexture(NULL, buf, w, h, 0, NULL);
		if (v->popTex) g_object_unref(v->popTex);
		v->popTex = t;
	} else {
		GdkTexture *t = frameTexture(v->tex, buf, w, h, n, dirty);
		if (v->tex) g_object_unref(v->tex);
		v->tex = t;
		if (g_getenv("IRIS_SHOT")) copyInto(&v->page, buf, w, h);
	}
	if (v->shown) redrawView();
}

static void CEF_CALLBACK onAcceleratedPaint(cef_render_handler_t *self, cef_browser_t *b, cef_paint_element_type_t type, size_t n,
                                            cef_rect_t const *dirty, const cef_accelerated_paint_info_t *info) {
	RELEASE(b); // frames come through the processor (shared_texture_enabled is off)
}

static void appendTexture(GtkSnapshot *s, GdkTexture *t, const graphene_rect_t *r, int sharp) {
	if (p_append_scaled) p_append_scaled(s, t, sharp ? GSK_SCALING_FILTER_NEAREST : GSK_SCALING_FILTER_LINEAR, r);
	else gtk_snapshot_append_texture(s, t, r);
}

// lgxSnapshotPages draws the pages on screen into the window's view, whose
// scale is s (the view has already been put on whole pixels).
void lgxSnapshotPages(GtkSnapshot *sn, double s) {
	if (!views || s <= 0) return;
	GHashTableIter it;
	gpointer k, val;
	g_hash_table_iter_init(&it, views);
	while (g_hash_table_iter_next(&it, &k, &val)) {
		LV *v = val;
		if (!v->shown || v->closing || v->px[2] <= 0 || v->px[3] <= 0) continue;
		graphene_rect_t r = GRAPHENE_RECT_INIT(v->px[0] / s, v->px[1] / s, v->px[2] / s, v->px[3] / s);
		gtk_snapshot_push_clip(sn, &r);
		if (v->tex) {
			int tw = gdk_texture_get_width(v->tex), th = gdk_texture_get_height(v->tex);
			if (abs(tw - v->px[2]) <= 1 && abs(th - v->px[3]) <= 1) {
				// one texel on one pixel: sharp
				appendTexture(sn, v->tex, &GRAPHENE_RECT_INIT(r.origin.x, r.origin.y, tw / s, th / s), 1);
			} else {
				// the page's place changed size and its frame for that size is
				// on its way: the last frame fills the place meanwhile, never a
				// smaller page beside a blank strip
				appendTexture(sn, v->tex, &r, 0);
			}
			if (v->popTex && v->popupShown) {
				int pw = gdk_texture_get_width(v->popTex), ph = gdk_texture_get_height(v->popTex);
				double x = round(v->px[0] + v->popupRect.x * dsf()) / s, y = round(v->px[1] + v->popupRect.y * dsf()) / s;
				appendTexture(sn, v->popTex, &GRAPHENE_RECT_INIT(x, y, pw / s, ph / s), 1);
			}
		} else {
			GdkRGBA white = {1, 1, 1, 1};
			gtk_snapshot_append_color(sn, &white, &r);
		}
		gtk_snapshot_pop(sn);
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
	// the scale Chromium was started at (it keeps it whatever this says)
	double sf = dsf();
	si->device_scale_factor = (float)sf;
	if (g_getenv("IRIS_GL_DEBUG")) g_printerr("Iris: page scale %.4g\n", sf);
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
	if (!show && v->popTex) g_clear_object(&v->popTex);
	redrawView();
}

static void CEF_CALLBACK onPopupSize(cef_render_handler_t *self, cef_browser_t *b, const cef_rect_t *r) {
	LV *v = of(b);
	if (v) v->popupRect = *r;
}

static cef_render_handler_t renderH;

// ---- input ----
//
// The window's view hands each pointer event here first (lgxPagePointer):
// the page under the pointer takes it, or the page a button was pressed on
// until it is released. Keys go to the focused page (lgxPageKey).

static LV *focusPage; // the page that has the keyboard (NULL: the interface)
static LV *hoverPage; // the page under the pointer
static LV *grabPage;  // the page a button is held on
static GtkIMContext *pageIM; // dead keys and input methods, for the pages
static guint32 lastClickTime;
static double lastClickX, lastClickY;
static int lastClickButton, clickCount;

static uint32_t modsOf(guint state) {
	uint32_t m = 0;
	if (state & GDK_SHIFT_MASK) m |= EVENTFLAG_SHIFT_DOWN;
	if (state & GDK_CONTROL_MASK) m |= EVENTFLAG_CONTROL_DOWN;
	if (state & GDK_ALT_MASK) m |= EVENTFLAG_ALT_DOWN;
	if (state & GDK_BUTTON1_MASK) m |= EVENTFLAG_LEFT_MOUSE_BUTTON;
	if (state & GDK_BUTTON2_MASK) m |= EVENTFLAG_MIDDLE_MOUSE_BUTTON;
	if (state & GDK_BUTTON3_MASK) m |= EVENTFLAG_RIGHT_MOUSE_BUTTON;
	if (state & GDK_LOCK_MASK) m |= EVENTFLAG_CAPS_LOCK_ON;
	return m;
}

// pageAt is the page shown at (x, y) in the view's units.
static LV *pageAt(double x, double y) {
	double s = scaleOf();
	double px = x * s, py = y * s;
	GHashTableIter it;
	gpointer k, val;
	g_hash_table_iter_init(&it, views);
	while (g_hash_table_iter_next(&it, &k, &val)) {
		LV *v = val;
		if (v->shown && !v->closing && v->browser && px >= v->px[0] && py >= v->px[1] && px < v->px[0] + v->px[2] && py < v->px[1] + v->px[3])
			return v;
	}
	return NULL;
}

// inPage is (x, y) in the page's own units.
static cef_mouse_event_t inPage(LV *v, double x, double y, guint state) {
	double s = scaleOf(), d = dsf();
	cef_mouse_event_t me = {(int)floor((x * s - v->px[0]) / d), (int)floor((y * s - v->px[1]) / d), modsOf(state)};
	return me;
}

static void setCursor(const char *name) {
	if (host) gtk_widget_set_cursor_from_name(host, name);
}

static void leavePage(LV *v, double x, double y, guint state) {
	cef_browser_host_t *h = hostOf(v);
	if (!h) return;
	cef_mouse_event_t me = inPage(v, x, y, state);
	h->send_mouse_move_event(h, &me, 1);
	RELEASE(h);
}

// focusOn gives the keyboard to page v (NULL: to the interface).
static void focusOn(LV *v) {
	if (focusPage == v) return;
	if (focusPage) {
		cef_browser_host_t *h = hostOf(focusPage);
		if (h) {
			h->set_focus(h, 0);
			RELEASE(h);
		}
		if (pageIM) gtk_im_context_focus_out(pageIM);
	}
	focusPage = v;
	if (v) {
		cef_browser_host_t *h = hostOf(v);
		if (h) {
			h->set_focus(h, 1);
			RELEASE(h);
		}
		if (pageIM) gtk_im_context_focus_in(pageIM);
	}
}

void lgxUIFocus(void) { focusOn(NULL); }

void lgxPagesLeave(void) {
	if (hoverPage && !grabPage) {
		leavePage(hoverPage, -1, -1, 0);
		hoverPage = NULL;
		setCursor(NULL);
	}
}

int lgxPagePointer(GdkEvent *e, double x, double y) {
	if (!views) return 0;
	GdkEventType t = gdk_event_get_event_type(e);
	guint state = gdk_event_get_modifier_state(e);
	LV *v = grabPage ? grabPage : pageAt(x, y);
	if (hoverPage && hoverPage != v && g_hash_table_lookup(views, (gpointer)hoverPage->id) == hoverPage) leavePage(hoverPage, x, y, state);
	if (v != hoverPage) {
		hoverPage = v;
		setCursor(v ? v->cursor : NULL);
	}
	if (!v) return 0;
	cef_browser_host_t *h = hostOf(v);
	if (!h) return 0;
	cef_mouse_event_t me = inPage(v, x, y, state);
	switch (t) {
	case GDK_BUTTON_PRESS:
	case GDK_BUTTON_RELEASE: {
		guint button = gdk_button_event_get_button(e);
		int press = t == GDK_BUTTON_PRESS;
		if (button == 8 || button == 9) { // the mouse's back and forward buttons
			if (press && v->browser) {
				if (button == 8) v->browser->go_back(v->browser);
				else v->browser->go_forward(v->browser);
			}
			break;
		}
		cef_mouse_button_type_t bt = button == 2 ? MBT_MIDDLE : button == 3 ? MBT_RIGHT : MBT_LEFT;
		if (press) {
			focusOn(v);
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
		h->send_mouse_click_event(h, &me, bt, !press, press ? clickCount : (clickCount ? clickCount : 1));
		break;
	}
	case GDK_MOTION_NOTIFY:
		h->send_mouse_move_event(h, &me, 0);
		break;
	case GDK_SCROLL: {
		double dx = 0, dy = 0;
		const double tick = 40; // pixels for one notch of the wheel
		switch (gdk_scroll_event_get_direction(e)) {
		case GDK_SCROLL_UP: dy = tick; break;
		case GDK_SCROLL_DOWN: dy = -tick; break;
		case GDK_SCROLL_LEFT: dx = tick; break;
		case GDK_SCROLL_RIGHT: dx = -tick; break;
		case GDK_SCROLL_SMOOTH: {
			double ex = 0, ey = 0;
			gdk_scroll_event_get_deltas(e, &ex, &ey);
			// a wheel's deltas are in notches, a touchpad's in pixels
			double k = p_scroll_unit && p_scroll_unit(e) == 1 ? 1 : tick;
			dx = -ex * k, dy = -ey * k;
			break;
		}
		}
		if ((me.modifiers & EVENTFLAG_SHIFT_DOWN) && dx == 0) {
			dx = dy; // Shift + wheel scrolls sideways
			dy = 0;
		}
		h->send_mouse_wheel_event(h, &me, (int)lround(dx), (int)lround(dy));
		break;
	}
	default:
		break;
	}
	RELEASE(h);
	return 1;
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

static void onCommit(GtkIMContext *im, const char *text, gpointer d) {
	if (focusPage) sendChars(focusPage, text, 0);
}

int lgxPageKey(GdkEvent *e) {
	LV *v = focusPage;
	if (!v || !views || g_hash_table_lookup(views, (gpointer)v->id) != v || !v->shown) return 0;
	cef_browser_host_t *h = hostOf(v);
	if (!h) return 0;
	GdkEventType type = gdk_event_get_event_type(e);
	guint state = gdk_event_get_modifier_state(e), kv = gdk_key_event_get_keyval(e);
	int ctrl = (state & GDK_CONTROL_MASK) != 0, shift = (state & GDK_SHIFT_MASK) != 0, alt = (state & GDK_ALT_MASK) != 0;
	int vk = winKey(kv);
	if (type == GDK_KEY_PRESS) {
		// Iris's own shortcuts first (Ctrl+T, Ctrl+L, F5, Alt+Left and so on)
		gunichar lc = gdk_keyval_to_unicode(gdk_keyval_to_lower(kv));
		int special = vk == 0x25 || vk == 0x27 || vk == 0x74 || vk == 0x75 || vk == 0x7A || vk == 0x09 || vk == 0x21 || vk == 0x22 || vk == 0xA6 ||
		              vk == 0xA7;
		if ((ctrl || alt || special) && lgxGoKey(v->id, (int)lc, special ? vk : 0, ctrl, shift, alt)) {
			RELEASE(h);
			return 1;
		}
	}
	cef_key_event_t k = {0};
	k.size = sizeof k;
	k.modifiers = modsOf(state);
	k.windows_key_code = vk;
	k.native_key_code = (int)gdk_key_event_get_keycode(e);
	gunichar ch = gdk_keyval_to_unicode(kv);
	if (type == GDK_KEY_PRESS) {
		k.type = KEYEVENT_RAWKEYDOWN;
		h->send_key_event(h, &k);
		// typed text goes through the input method (dead keys: ´ then e is é)
		if (!ctrl && !alt && pageIM && gtk_im_context_filter_keypress(pageIM, e)) {
			RELEASE(h);
			return 1;
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
		if (pageIM) gtk_im_context_filter_keypress(pageIM, e);
		k.type = KEYEVENT_KEYUP;
		h->send_key_event(h, &k);
	}
	RELEASE(h);
	return 1;
}

// forget drops a page that is going away from the input's memory.
static void forget(LV *v) {
	if (focusPage == v) focusPage = NULL;
	if (hoverPage == v) hoverPage = NULL, setCursor(NULL);
	if (grabPage == v) grabPage = NULL;
}


// ---- the right-click menu ----
//
// Chromium's own menu needs a window, and pages here are drawn off screen,
// so Iris shows the menu: a GTK popover menu with Chromium's items (back, forward,
// reload, cut, copy, paste, select all, save or copy an image…) and, on a
// link or a picture, opening it in a new tab and copying its address.

enum {
	CMD_LINK_TAB = MENU_ID_USER_FIRST,
	CMD_LINK_SAVE,
	CMD_LINK_COPY,
	CMD_IMAGE_TAB,
	CMD_IMAGE_SAVE,
	CMD_IMAGE_COPY_URL,
	CMD_SEARCH,
};

static cef_run_context_menu_callback_t *menuCb; // the menu on screen
static char *menuLink, *menuImage, *menuText;

static void menuFinish(int cmd) {
	if (!menuCb) return;
	cef_run_context_menu_callback_t *cb = menuCb;
	menuCb = NULL;
	if (cmd >= 0) cb->cont(cb, cmd, EVENTFLAG_NONE);
	else cb->cancel(cb);
	RELEASE(cb);
}

static void onMenuAction(GSimpleAction *a, GVariant *p, gpointer cmd) { menuFinish(GPOINTER_TO_INT(cmd)); }

static gboolean menuCancel(gpointer _) {
	menuFinish(-1); // closed without a choice (an item's choice came first)
	return G_SOURCE_REMOVE;
}

static gboolean menuDrop(gpointer pop) {
	if (gtk_widget_get_parent(pop)) gtk_widget_unparent(pop);
	g_object_unref(pop);
	return G_SOURCE_REMOVE;
}

static void onMenuClosed(GtkPopover *p, gpointer _) {
	g_idle_add(menuCancel, NULL);
	g_idle_add(menuDrop, g_object_ref(p));
}

// label turns Chromium's label ("&Copy") into GTK's ("_Copy").
static char *menuLabel(cef_menu_model_t *model, size_t i) {
	cef_string_userfree_t l = model->get_label_at(model, i);
	char *s = l ? getStr(l) : g_strdup("");
	if (l) cef_string_userfree_free(l);
	GString *o = g_string_new(NULL);
	for (char *p = s; *p; p++) {
		if (*p == '&') {
			if (p[1] == '&') o = g_string_append_c(o, '&'), p++;
			else o = g_string_append_c(o, '_');
		} else if (*p == '_') {
			g_string_append(o, "__");
		} else {
			g_string_append_c(o, *p);
		}
	}
	g_free(s);
	return g_string_free(o, FALSE);
}

static void CEF_CALLBACK onBeforeMenu(cef_context_menu_handler_t *self, cef_browser_t *b, cef_frame_t *f, cef_context_menu_params_t *params,
                                      cef_menu_model_t *model) {
	RELEASE(b);
	RELEASE(f);
	g_free(menuLink);
	g_free(menuImage);
	g_free(menuText);
	cef_string_userfree_t sel = params->get_selection_text(params);
	menuText = sel ? getStr(sel) : NULL;
	if (sel) cef_string_userfree_free(sel);
	if (menuText) g_strstrip(menuText);
	cef_string_userfree_t l = params->get_link_url(params);
	menuLink = l ? getStr(l) : NULL;
	if (l) cef_string_userfree_free(l);
	cef_string_userfree_t src = params->get_source_url(params);
	menuImage = src && params->get_media_type(params) == CM_MEDIATYPE_IMAGE ? getStr(src) : NULL;
	if (src) cef_string_userfree_free(src);
	// Chrome's items first, in Chrome's order; Chromium's own (back,
	// forward, reload, print, view source, cut, copy, paste) follow
	cef_string_t t = {0};
	size_t at = 0;
	if (menuLink && *menuLink) {
		setStr(&t, "Open link in new tab");
		model->insert_item_at(model, at++, CMD_LINK_TAB, &t);
		setStr(&t, "Save link as…");
		model->insert_item_at(model, at++, CMD_LINK_SAVE, &t);
		setStr(&t, "Copy link address");
		model->insert_item_at(model, at++, CMD_LINK_COPY, &t);
	}
	if (menuImage && *menuImage) {
		if (at) model->insert_separator_at(model, at++);
		setStr(&t, "Open image in new tab");
		model->insert_item_at(model, at++, CMD_IMAGE_TAB, &t);
		setStr(&t, "Save image as…");
		model->insert_item_at(model, at++, CMD_IMAGE_SAVE, &t);
		setStr(&t, "Copy image address");
		model->insert_item_at(model, at++, CMD_IMAGE_COPY_URL, &t);
	}
	if (menuText && *menuText) {
		// "Search Google for “…”", the selection cut short as Chrome does
		glong n = g_utf8_strlen(menuText, -1);
		char *shown = n > 32 ? g_strdup_printf("%.*s…", (int)(g_utf8_offset_to_pointer(menuText, 30) - menuText), menuText) : g_strdup(menuText);
		for (char *c = shown; *c; c++)
			if (*c == '\n' || *c == '\t') *c = ' ';
		char *label = g_strdup_printf("Search Google for “%s”", shown);
		if (at) model->insert_separator_at(model, at++);
		setStr(&t, label);
		model->insert_item_at(model, at++, CMD_SEARCH, &t);
		g_free(label);
		g_free(shown);
	}
	if (at && model->get_count(model) > at) model->insert_separator_at(model, at);
	cef_string_clear(&t);
	RELEASE(params);
	RELEASE(model);
}

static int CEF_CALLBACK onRunMenu(cef_context_menu_handler_t *self, cef_browser_t *b, cef_frame_t *f, cef_context_menu_params_t *params,
                                  cef_menu_model_t *model, cef_run_context_menu_callback_t *cb) {
	LV *v = of(b);
	RELEASE(f);
	if (!v || !host || !gtk_widget_get_realized(host) || model->get_count(model) == 0) {
		cb->cancel(cb);
		RELEASE(cb);
		RELEASE(params);
		RELEASE(model);
		return 1;
	}
	if (menuCb) menuFinish(-1);
	menuCb = cb; // kept until a choice or the menu closes
	// a GTK popover menu: one section per group (sections are what draws
	// the separators), one action per item
	GMenu *menu = g_menu_new(), *sec = g_menu_new();
	GSimpleActionGroup *acts = g_simple_action_group_new();
	for (size_t i = 0; i < model->get_count(model); i++) {
		cef_menu_item_type_t type = model->get_type_at(model, i);
		if (type == MENUITEMTYPE_SEPARATOR) {
			if (g_menu_model_get_n_items(G_MENU_MODEL(sec)) > 0) {
				g_menu_append_section(menu, NULL, G_MENU_MODEL(sec));
				g_object_unref(sec);
				sec = g_menu_new();
			}
			continue;
		}
		if (type != MENUITEMTYPE_COMMAND && type != MENUITEMTYPE_CHECK) continue; // no submenus
		if (!model->is_visible_at(model, i)) continue;
		int cmd = model->get_command_id_at(model, i);
		char name[24], detailed[32];
		snprintf(name, sizeof name, "c%zu", i);
		snprintf(detailed, sizeof detailed, "ctx.%s", name);
		GSimpleAction *a = g_simple_action_new(name, NULL);
		g_simple_action_set_enabled(a, model->is_enabled_at(model, i));
		g_signal_connect(a, "activate", G_CALLBACK(onMenuAction), GINT_TO_POINTER(cmd));
		g_action_map_add_action(G_ACTION_MAP(acts), G_ACTION(a));
		g_object_unref(a);
		char *label = menuLabel(model, i);
		g_menu_append(sec, label, detailed);
		g_free(label);
	}
	if (g_menu_model_get_n_items(G_MENU_MODEL(sec)) > 0) g_menu_append_section(menu, NULL, G_MENU_MODEL(sec));
	g_object_unref(sec);
	gtk_widget_insert_action_group(host, "ctx", G_ACTION_GROUP(acts));
	g_object_unref(acts);
	GtkWidget *pop = gtk_popover_menu_new_from_model(G_MENU_MODEL(menu));
	g_object_unref(menu);
	gtk_widget_set_parent(pop, host);
	gtk_popover_set_has_arrow(GTK_POPOVER(pop), FALSE);
	gtk_popover_set_position(GTK_POPOVER(pop), GTK_POS_BOTTOM);
	gtk_widget_set_halign(pop, GTK_ALIGN_START);
	double s = scaleOf(), d = dsf();
	GdkRectangle at = {(int)((v->px[0] + params->get_xcoord(params) * d) / s), (int)((v->px[1] + params->get_ycoord(params) * d) / s), 1, 1};
	gtk_popover_set_pointing_to(GTK_POPOVER(pop), &at);
	g_signal_connect(pop, "closed", G_CALLBACK(onMenuClosed), NULL);
	gtk_popover_popup(GTK_POPOVER(pop));
	RELEASE(params);
	RELEASE(model);
	return 1;
}

static int CEF_CALLBACK onMenuCommand(cef_context_menu_handler_t *self, cef_browser_t *b, cef_frame_t *f, cef_context_menu_params_t *params,
                                      int cmd, cef_event_flags_t flags) {
	LV *v = of(b);
	RELEASE(f);
	RELEASE(params);
	if (cmd == CMD_SEARCH) {
		if (!v || !menuText || !*menuText) return 1;
		char *q = g_uri_escape_string(menuText, NULL, FALSE);
		char *u = g_strdup_printf("https://www.google.com/search?q=%s", q);
		lgxGoOpenTab(v->id, u);
		g_free(u);
		g_free(q);
		return 1;
	}
	const char *u = cmd == CMD_LINK_TAB || cmd == CMD_LINK_SAVE || cmd == CMD_LINK_COPY ? menuLink
	              : cmd == CMD_IMAGE_TAB || cmd == CMD_IMAGE_SAVE || cmd == CMD_IMAGE_COPY_URL ? menuImage
	                                                                                           : NULL;
	if (!u || !*u) return 0; // Chromium's own command
	if (cmd == CMD_LINK_TAB || cmd == CMD_IMAGE_TAB) {
		if (v) lgxGoOpenTab(v->id, (char *)u);
	} else if (cmd == CMD_LINK_SAVE || cmd == CMD_IMAGE_SAVE) {
		// into Downloads, through the download handler (name, shields, limits)
		cef_browser_host_t *host2 = hostOf(v);
		if (host2) {
			cef_string_t su = {0};
			setStr(&su, u);
			host2->start_download(host2, &su);
			cef_string_clear(&su);
			RELEASE(host2);
		}
	} else {
		gdk_clipboard_set_text(gdk_display_get_clipboard(gdk_display_get_default()), u);
	}
	return 1;
}

static cef_context_menu_handler_t menuH;
static cef_context_menu_handler_t *CEF_CALLBACK getMenu(cef_client_t *self) { return &menuH; }

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

// A script's result comes back marked with its callback and a secret made
// for that one call; it counts only from the page it was sent to, once.
// (A page can print the mark itself: without the secret and the right page
// it is ignored, so a page can neither fake an answer nor crash Iris.)
typedef struct {
	int bid;
	guint64 secret;
} EvalWait;
static GHashTable *evalWaits; // callback -> EvalWait*

static int CEF_CALLBACK onConsole(cef_display_handler_t *self, cef_browser_t *b, cef_log_severity_t level, const cef_string_t *msg,
                                  const cef_string_t *src, int line) {
	int bid = b ? b->get_identifier(b) : -1;
	RELEASE(b);
	char *m = getStr(msg);
	int ours = 0;
	if (g_str_has_prefix(m, RESULT_MARK)) {
		ours = 1;
		char *rest = m + strlen(RESULT_MARK);
		char *c1 = strchr(rest, ':');
		char *c2 = c1 ? strchr(c1 + 1, ':') : NULL;
		if (c1 && c2 && evalWaits) {
			*c1 = 0;
			*c2 = 0;
			uintptr_t cb = (uintptr_t)g_ascii_strtoull(rest, NULL, 10);
			guint64 secret = g_ascii_strtoull(c1 + 1, NULL, 16);
			EvalWait *w = cb ? g_hash_table_lookup(evalWaits, GSIZE_TO_POINTER(cb)) : NULL;
			if (w && w->secret == secret && w->bid == bid) {
				g_hash_table_remove(evalWaits, GSIZE_TO_POINTER(cb));
				lgxGoResult(cb, c2 + 1);
			}
		}
	}
	g_free(m);
	return ours;
}

static int CEF_CALLBACK onCursor(cef_display_handler_t *self, cef_browser_t *b, cef_cursor_handle_t c, cef_cursor_type_t type, const cef_cursor_info_t *info) {
	LV *v = of(b);
	if (!v) return 1;
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
	v->cursor = name; // names are constants
	if (v == hoverPage) setCursor(name);
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
	v->scale = dsf();
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
	forget(v);
	if (v->tex) g_object_unref(v->tex);
	if (v->popTex) g_object_unref(v->popTex);
	if (v->page) cairo_surface_destroy(v->page);
	redrawView();
	g_slist_free_full(v->scripts, g_free);
	g_free(v->profile);
	g_free(v->startURL);
	g_free(v->pageURL);
	g_free(v);
}

// A link or a script asks for a new window: Iris opens a tab (or not),
// and that tab's page loads the address.
static int CEF_CALLBACK onBeforePopup(cef_life_span_handler_t *self, cef_browser_t *b, cef_frame_t *f, int popupID, const cef_string_t *url,
                                      const cef_string_t *name, cef_window_open_disposition_t disp, int gesture, const cef_popup_features_t *feat,
                                      cef_window_info_t *wi, cef_client_t **client, cef_browser_settings_t *settings, cef_dictionary_value_t **extra,
                                      int *noJS) {
	RELEASE(f);
	LV *v = of(b);
	if (!v) return 1;
	// a window the person did not ask for (no click or key just before) is
	// not opened: no popup ads, no tabs opened by themselves
	if (!gesture) return 1;
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
	if (v && v->sandbox) return 0; // nothing from a sandbox reaches the disk
	// a page may not flood the disk: at most six downloads in half a minute
	static gint64 times[6];
	static int next;
	gint64 now = g_get_monotonic_time();
	if (times[next] && now - times[next] < 30 * G_USEC_PER_SEC) return 0;
	times[next] = now;
	next = (next + 1) % 6;
	return 1;
}

// safeName makes a page's suggested file name a plain one: no folders,
// no control characters, no hidden file, and short enough for the disk.
static char *safeName(const char *suggested) {
	char *base = g_path_get_basename(suggested && *suggested ? suggested : "download");
	GString *o = g_string_new(NULL);
	for (const char *p = base; *p; p++) {
		unsigned char c = (unsigned char)*p;
		if (c < 0x20 || c == 0x7f || c == '/' || c == '\\') continue;
		g_string_append_c(o, (char)c);
	}
	g_free(base);
	while (o->len && (o->str[0] == '.' || o->str[0] == ' ' || o->str[0] == '-')) g_string_erase(o, 0, 1);
	if (!o->len || !g_utf8_validate(o->str, -1, NULL)) {
		g_string_free(o, TRUE);
		return g_strdup("download");
	}
	if (o->len > 180) {
		// keep the end (the extension) and cut the middle, on a character boundary
		const char *dot = strrchr(o->str, '.');
		size_t ext = dot && strlen(dot) <= 16 ? strlen(dot) : 0;
		const char *cut = g_utf8_find_prev_char(o->str, o->str + 180 - ext);
		GString *t = g_string_new_len(o->str, cut ? cut - o->str : 0);
		if (ext) g_string_append(t, dot);
		g_string_free(o, TRUE);
		o = t;
	}
	return g_string_free(o, FALSE);
}

static char *freePath(const char *suggested) {
	const char *dir = g_get_user_special_dir(G_USER_DIRECTORY_DOWNLOAD);
	char *home = NULL;
	if (!dir) dir = home = g_build_filename(g_get_home_dir(), "Downloads", NULL);
	g_mkdir_with_parents(dir, 0755);
	char *name = safeName(suggested);
	char *path = g_build_filename(dir, name, NULL);
	// names given out this run count as taken too: two downloads of one name
	// at once do not write into one file
	static GHashTable *taken;
	if (!taken) taken = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
	for (int n = 1; (g_file_test(path, G_FILE_TEST_EXISTS) || g_hash_table_contains(taken, path)) && n < 1000; n++) {
		char *dot = strrchr(name, '.');
		char *stem = dot && dot != name ? g_strndup(name, dot - name) : g_strdup(name);
		char *next = g_strdup_printf("%s (%d)%s", stem, n + 1, dot && dot != name ? dot : "");
		g_free(path);
		path = g_build_filename(dir, next, NULL);
		g_free(stem);
		g_free(next);
	}
	g_hash_table_add(taken, g_strdup(path));
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
	renderH.on_accelerated_paint = onAcceleratedPaint;
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
	STATIC_BASE(menuH);
	menuH.on_before_context_menu = onBeforeMenu;
	menuH.run_context_menu = onRunMenu;
	menuH.on_context_menu_command = onMenuCommand;

	STATIC_BASE(client);
	client.get_render_handler = getRender;
	client.get_display_handler = getDisplay;
	client.get_load_handler = getLoad;
	client.get_life_span_handler = getLife;
	client.get_request_handler = getRequest;
	client.get_download_handler = getDownload;
	client.get_permission_handler = getPerm;
	client.get_context_menu_handler = getMenu;
}

// ---- containers: each profile is a request context with its own storage ----

// scheme is the pages' color mode: 0 the system's, 1 light, 2 dark (the
// browser's palette); every request context gets it.
static int scheme = 0;

static void applyScheme(cef_request_context_t *c) {
	static const cef_color_variant_t modes[] = {CEF_COLOR_VARIANT_SYSTEM, CEF_COLOR_VARIANT_LIGHT, CEF_COLOR_VARIANT_DARK};
	if (c && c->set_chrome_color_scheme) c->set_chrome_color_scheme(c, modes[scheme], 0);
}

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
	applyScheme(c);
	return c;
}

static void createBrowser(LV *v) {
	cef_window_info_t wi = {0};
	wi.size = sizeof wi;
	wi.windowless_rendering_enabled = 1;
	wi.shared_texture_enabled = 0; // frames come through the processor: they work everywhere
	wi.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
	cef_browser_settings_t bs = {0};
	bs.size = sizeof bs;
	bs.windowless_frame_rate = 60;
	bs.background_color = scheme == 2 ? 0xFF1C1C1E : 0xFFFFFFFF; // no white flash in dark mode
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
		// the result comes back as a marked console message (onConsole), with
		// a secret for this call only
		if (!evalWaits) evalWaits = g_hash_table_new_full(g_direct_hash, g_direct_equal, NULL, g_free);
		EvalWait *w = g_new0(EvalWait, 1);
		w->bid = v->bid;
		w->secret = ((guint64)g_random_int() << 32) | g_random_int();
		g_hash_table_replace(evalWaits, GSIZE_TO_POINTER(cb), w);
		code = g_strdup_printf("(async () => { let r = 'null'; try { const v = await (0, eval)(%s); r = JSON.stringify(v === undefined ? null : v); "
		                       "if (r === undefined) r = 'null'; } catch (e) {} console.log('\\x01lgx-result:%" G_GUINT64_FORMAT ":%" G_GINT64_MODIFIER "x:' + r); })();",
		                       js, (guint64)cb, w->secret);
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
	if (!cefStarting && startDir) { // Chromium is not started yet: after it is
		g_queue_push_tail(&early, data);
		return G_SOURCE_REMOVE;
	}
	Op *op = data;
	LV *v = op->id && op->op != OP_DLCANCEL ? lv(op->id, op->op == OP_SCRIPT || op->op == OP_PROFILE || op->op == OP_NEW) : NULL;
	cef_browser_host_t *h = v ? hostOf(v) : NULL;
	switch (op->op) {
	case OP_SCHEME: {
		scheme = op->a >= 0 && op->a <= 2 ? op->a : 0;
		if (contexts) {
			GHashTableIter it;
			gpointer k, c;
			g_hash_table_iter_init(&it, contexts);
			while (g_hash_table_iter_next(&it, &k, &c)) applyScheme(c);
		}
		break;
	}
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
			// where the page goes, in the view's real pixels; its size in
			// Chromium's units, so its frame has exactly that many pixels
			double sf = dsf();
			v->px[0] = op->a, v->px[1] = op->b, v->px[2] = op->c, v->px[3] = op->d;
			int w = (int)lround(op->c / sf), hh = (int)lround(op->d / sf);
			if (w < 1) w = 1;
			if (hh < 1) hh = 1;
			if (h && fabs(sf - v->scale) > 0.001) {
				// the window moved to a screen with another scale (or the first
				// size arrived before the window knew its scale)
				v->scale = sf;
				h->notify_screen_info_changed(h);
			}
			redrawView();
			if (w != v->w || hh != v->h) {
				v->w = w, v->h = hh;
				if (h) h->was_resized(h);
			}
		}
		break;
	case OP_SHOW:
		if (v) {
			v->shown = op->a;
			if (!op->a) forget(v);
			redrawView();
			if (h) h->was_hidden(h, !op->a);
			// a page resized while hidden may not have drawn at its new size:
			// shown, it is asked to
			if (h && op->a) h->was_resized(h);
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
			if (host) gtk_widget_grab_focus(host);
			focusOn(v);
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
			forget(v);
			redrawView();
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

// With IRIS_SHOT=<prefix> set (the tests), the page on screen is written
// to <prefix>-1.png, -2.png and so on, every five seconds.
static gboolean shotTick(gpointer d) {
	static int n;
	const char *pre = g_getenv("IRIS_SHOT");
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
			g_printerr("Iris: page written to %s (%dx%d)\n", path, cairo_image_surface_get_width(v->page), cairo_image_surface_get_height(v->page));
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

// tables are the pages' tables, there from the first moment (input and
// drawing look at them before Chromium starts)
static void tables(void) {
	if (views) return;
	views = g_hash_table_new(g_direct_hash, g_direct_equal);
	byBrowser = g_hash_table_new(g_direct_hash, g_direct_equal);
	contexts = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
	downloads = g_hash_table_new(g_direct_hash, g_direct_equal);
}

static void setup(const char *dir) {
	if (cefStarting) return;
	cefStarting = 1;
	tables();
	dataDir = g_strdup(dir);
	initHandlers();
	cef_api_hash(CEF_API_VERSION, 0);

	char *bin = exeDir();
	char *helper = g_build_filename(bin, "iris-helper", NULL);
	char *root = g_build_filename(dir, "cef", NULL);
	char *locales = g_build_filename(bin, "locales", NULL);
	g_mkdir_with_parents(root, 0700);

	cef_settings_t s = {0};
	s.size = sizeof s;
	noSandbox = sandboxMissing(bin);
	if (noSandbox) g_printerr("Iris: Chromium runs without its sandbox here (no setuid chrome-sandbox, no user namespaces)\n");
	s.no_sandbox = noSandbox;
	s.external_message_pump = 1;
	s.multi_threaded_message_loop = 0;
	s.windowless_rendering_enabled = 1;
	s.persist_session_cookies = 1;
	// Chromium speaks only when asked (IRIS_CEF_VERBOSE=1): its messages about the
	// system bus, the battery or VA-API inside a toolbox are noise, not errors
	s.log_severity = g_getenv("IRIS_CEF_VERBOSE") ? LOGSEVERITY_INFO : LOGSEVERITY_FATAL;
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
	if (!started) g_printerr("Iris: Chromium (CEF) could not start\n");
	// a steady beat as well, for work CEF does not schedule
	g_timeout_add(250, pumpTick, NULL); // CEF schedules its own work; this beat only catches what it did not
	if (g_getenv("IRIS_SHOT")) g_timeout_add_seconds(5, shotTick, NULL);
	g_free(bin);
	g_free(helper);
	g_free(root);
	g_free(locales);
}

// startWhenSettled starts Chromium once the window is on screen and its
// scale has held for 150 ms (the compositor corrects GTK's first guess a
// frame or two after the window shows), or after 1.5 s at the latest. What
// the interface asks of the pages meanwhile waits (early) and runs then.
static void startNow(void);

static gboolean startWhenSettled(GtkWidget *w, GdkFrameClock *fc, gpointer d) {
	gint64 now = g_get_monotonic_time();
	double sc = scaleOf();
	if (fabs(sc - lastScale) > 0.001) lastScale = sc, scaleSince = now;
	int settled = gtk_widget_get_mapped(w) && now - scaleSince >= 150000;
	if (cefStarting) return G_SOURCE_REMOVE;
	if (!settled && now - startAt < 1500000) return G_SOURCE_CONTINUE;
	startNow();
	return G_SOURCE_REMOVE;
}

// startNow starts Chromium at the window's scale as it is now.
static void startNow(void) {
	if (cefStarting) return;
	double sc = scaleOf();
	pageDSF = g_getenv("IRIS_SCALE") ? g_ascii_strtod(g_getenv("IRIS_SCALE"), NULL) : sc;
	if (pageDSF < 0.5 || pageDSF > 8) pageDSF = sc;
	if (g_getenv("IRIS_GL_DEBUG")) g_printerr("Iris: pages at scale %.4g\n", pageDSF);
	setup(startDir);
	while (!g_queue_is_empty(&early)) runOp(g_queue_pop_head(&early));
}

// the window drew no frames (opened minimized, say): Chromium starts anyway
static gboolean startLate(gpointer d) {
	startNow();
	return G_SOURCE_REMOVE;
}

// lgxAttach starts the engine in Iris's GTK window (on GTK's thread); view
// is the widget the pages are drawn in.
void lgxAttach(uintptr_t view, const char *dir) {
	loadSyms();
	host = (GtkWidget *)view;
	g_object_add_weak_pointer(G_OBJECT(host), (gpointer *)&host);
	pageIM = gtk_im_context_simple_new();
	gtk_im_context_set_client_widget(pageIM, host);
	g_signal_connect(pageIM, "commit", G_CALLBACK(onCommit), NULL);
	tables();
	startDir = g_strdup(dir);
	startAt = g_get_monotonic_time();
	gtk_widget_add_tick_callback(host, startWhenSettled, NULL, NULL);
	g_timeout_add(1800, startLate, NULL);
}

// lgxMain is the Gio-window variant, which the Chromium engine does not use.
void lgxMain(unsigned long parent, const char *dir) {
	gtk_init();
	setup(dir);
	g_main_loop_run(g_main_loop_new(NULL, FALSE));
}

char *lgxVersion(void) {
	char buf[64];
	snprintf(buf, sizeof buf, "Chromium %d.%d.%d.%d", CHROME_VERSION_MAJOR, CHROME_VERSION_MINOR, CHROME_VERSION_BUILD, CHROME_VERSION_PATCH);
	return strdup(buf);
}
