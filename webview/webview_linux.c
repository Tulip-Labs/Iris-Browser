//go:build linux && webkit

// The Linux side of Lite Go's web engine: WebKitGTK views.
//
// Normally Lite Go's own window is a GTK window (cmd/litego/gtk_linux.c) and
// the views are children of its GtkLayout, over the interface: one window,
// native on Wayland and X11, on GTK's main thread. A Gio X11 window can still
// host them instead, each in a GtkPlug, with GTK on a thread of its own.
// Either way every call from Go goes through g_main_context_invoke, which runs
// it at once on the GTK thread and queues it from any other.

#include <gtk/gtk.h>
#include <gtk/gtkx.h>
#include <webkit2/webkit2.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

enum { OP_NEW = 1, OP_NAV, OP_BACK, OP_FWD, OP_RELOAD, OP_STOP, OP_BOUNDS, OP_SHOW, OP_FOCUS, OP_EVAL, OP_MUTE, OP_CLOSE, OP_SCRIPT, OP_PROFILE, OP_PRIVATE, OP_BLOCKLIST, OP_ZOOM, OP_DLCANCEL };

extern void lgxGoCreated(uintptr_t cb, int ok);
extern void lgxGoURL(uintptr_t id, char *u);
extern void lgxGoTitle(uintptr_t id, char *t);
extern void lgxGoLoading(uintptr_t id, int on, int back, int fwd);
extern char *lgxGoDecide(uintptr_t id, char *u);
extern uintptr_t lgxGoPopup(uintptr_t id, char *u);
extern void lgxGoFullscreen(uintptr_t id, int on);
extern void lgxGoCrashed(uintptr_t id);
extern void lgxGoAudio(uintptr_t id, int on);
extern int lgxGoKey(uintptr_t id, int ch, int vk, int ctrl, int shift, int alt);
extern void lgxGoResult(uintptr_t cb, char *res);
extern void lgxGoFocus(uintptr_t id);
extern void lgxGoDownload(uintptr_t id, uintptr_t view, int state, char *url, char *path, long long total, long long got);

enum { DL_ACTIVE = 0, DL_DONE = 2, DL_FAILED = 3, DL_CANCELED = 4 };

typedef struct {
	uintptr_t id;
	WebKitWebView *web;
	GtkWidget *plug;
	WebKitUserContentManager *ucm;
	GSList *scripts; // queued before the view exists
	char *profile;
	int priv;
	int sandbox; // a page that may be unsafe: no downloads, no permissions
} LV;

static unsigned long parentXID;
static GtkLayout *host; // the window's layout when GTK owns the window
static char *dataDir;
static GHashTable *views;    // id -> LV*
static GHashTable *contexts; // profile -> WebKitWebContext*
static WebKitUserContentFilter *filter;
static GHashTable *downloads; // id -> WebKitDownload*
static uintptr_t lastDownload;

// ---- downloads ----

static void dlReport(WebKitDownload *d, int state) {
	uintptr_t id = (uintptr_t)g_object_get_data(G_OBJECT(d), "lgx-id");
	WebKitURIRequest *rq = webkit_download_get_request(d);
	const char *u = rq ? webkit_uri_request_get_uri(rq) : NULL;
	const char *dest = webkit_download_get_destination(d); // a file:// address
	char *path = dest ? g_filename_from_uri(dest, NULL, NULL) : NULL;
	WebKitURIResponse *rs = webkit_download_get_response(d);
	long long total = rs ? (long long)webkit_uri_response_get_content_length(rs) : 0;
	uintptr_t owner = (uintptr_t)g_object_get_data(G_OBJECT(d), "lgx-view");
	lgxGoDownload(id, owner, state, (char *)(u ? u : ""), path ? path : "", total > 0 ? total : -1, (long long)webkit_download_get_received_data_length(d));
	g_free(path);
}

static gboolean dlDestination(WebKitDownload *d, gchar *suggested, gpointer data) {
	const char *dir = g_get_user_special_dir(G_USER_DIRECTORY_DOWNLOAD);
	char *home = NULL;
	if (!dir) dir = home = g_build_filename(g_get_home_dir(), "Downloads", NULL);
	g_mkdir_with_parents(dir, 0755);
	char *name = g_path_get_basename(suggested && *suggested ? suggested : "download");
	char *path = g_build_filename(dir, name, NULL);
	for (int n = 1; g_file_test(path, G_FILE_TEST_EXISTS) && n < 1000; n++) {
		// "name (2).ext" beside what is already there
		char *dot = strrchr(name, '.');
		char *stem = dot && dot != name ? g_strndup(name, dot - name) : g_strdup(name);
		char *next = g_strdup_printf("%s (%d)%s", stem, n + 1, dot && dot != name ? dot : "");
		g_free(path);
		path = g_build_filename(dir, next, NULL);
		g_free(stem);
		g_free(next);
	}
	char *uri = g_filename_to_uri(path, NULL, NULL);
	if (uri) webkit_download_set_destination(d, uri);
	g_free(uri);
	g_free(path);
	g_free(name);
	g_free(home);
	dlReport(d, DL_ACTIVE);
	return TRUE;
}

static void dlData(WebKitDownload *d, guint64 n, gpointer data) {
	gint64 now = g_get_monotonic_time();
	gint64 last = (gint64)(gintptr)g_object_get_data(G_OBJECT(d), "lgx-at");
	if (now / 200000 == last) return; // five reports a second are plenty
	g_object_set_data(G_OBJECT(d), "lgx-at", (gpointer)(gintptr)(now / 200000));
	dlReport(d, DL_ACTIVE);
}

static void dlFailed(WebKitDownload *d, GError *err, gpointer data) {
	int canceled = err && g_error_matches(err, WEBKIT_DOWNLOAD_ERROR, WEBKIT_DOWNLOAD_ERROR_CANCELLED_BY_USER);
	g_object_set_data(G_OBJECT(d), "lgx-failed", GINT_TO_POINTER(1));
	dlReport(d, canceled ? DL_CANCELED : DL_FAILED);
}

static void dlFinished(WebKitDownload *d, gpointer data) {
	if (!g_object_get_data(G_OBJECT(d), "lgx-failed")) dlReport(d, DL_DONE);
	g_hash_table_remove(downloads, g_object_get_data(G_OBJECT(d), "lgx-id"));
}

static void onDownload(WebKitWebContext *c, WebKitDownload *d, gpointer data) {
	if (g_object_get_data(G_OBJECT(c), "lgx-sandbox")) {
		webkit_download_cancel(d); // nothing from a sandbox reaches the disk
		return;
	}
	uintptr_t id = ++lastDownload;
	g_object_set_data(G_OBJECT(d), "lgx-id", (gpointer)id);
	WebKitWebView *w = webkit_download_get_web_view(d);
	if (w) g_object_set_data(G_OBJECT(d), "lgx-view", g_object_get_data(G_OBJECT(w), "lgx-view"));
	g_hash_table_insert(downloads, (gpointer)id, g_object_ref(d));
	g_signal_connect(d, "decide-destination", G_CALLBACK(dlDestination), NULL);
	g_signal_connect(d, "received-data", G_CALLBACK(dlData), NULL);
	g_signal_connect(d, "failed", G_CALLBACK(dlFailed), NULL);
	g_signal_connect(d, "finished", G_CALLBACK(dlFinished), NULL);
}

static LV *lv(uintptr_t id, int make) {
	LV *v = g_hash_table_lookup(views, (gpointer)id);
	if (!v && make) {
		v = g_new0(LV, 1);
		v->id = id;
		g_hash_table_insert(views, (gpointer)id, v);
	}
	return v;
}

// Memory. memTotalMB is the computer's memory (lgxSetMemory, before the
// first page). Each page's process is told how much it may use: past a third
// of that it starts giving memory back, past a half it does so hard. On
// computers with 8 GB or less, the caches are the small ones (no whole pages
// kept for Back and Forward).
static int memTotalMB;

void lgxSetMemory(int totalMB) { memTotalMB = totalMB; }

static WebKitMemoryPressureSettings *pressureSettings(void) {
	static WebKitMemoryPressureSettings *s;
	if (s || memTotalMB <= 0) return s;
	int limit = memTotalMB / 10;
	if (limit < 384) limit = 384;
	if (limit > 1536) limit = 1536;
	s = webkit_memory_pressure_settings_new();
	webkit_memory_pressure_settings_set_memory_limit(s, limit);
	webkit_memory_pressure_settings_set_conservative_threshold(s, 0.33);
	webkit_memory_pressure_settings_set_strict_threshold(s, 0.5);
	webkit_memory_pressure_settings_set_poll_interval(s, 5);
	// the network processes made from now on get the same limits
	webkit_website_data_manager_set_memory_pressure_settings(s);
	return s;
}

static WebKitWebContext *contextFor(const char *profile, int priv, int sandbox) {
	char key[512];
	snprintf(key, sizeof key, "%s%s:%s", priv ? "private" : "disk", sandbox ? "+sandbox" : "", profile);
	WebKitWebContext *c = g_hash_table_lookup(contexts, key);
	if (c) return c;
	WebKitWebsiteDataManager *m;
	if (priv) {
		m = webkit_website_data_manager_new_ephemeral();
	} else {
		char *base = g_build_filename(dataDir, *profile ? profile : "default", NULL);
		char *cache = g_build_filename(dataDir, "cache", *profile ? profile : "default", NULL);
		m = webkit_website_data_manager_new("base-data-directory", base, "base-cache-directory", cache, NULL);
		g_free(base);
		g_free(cache);
	}
	WebKitMemoryPressureSettings *ps = pressureSettings();
	if (ps) {
		c = WEBKIT_WEB_CONTEXT(g_object_new(WEBKIT_TYPE_WEB_CONTEXT, "website-data-manager", m, "memory-pressure-settings", ps, NULL));
	} else {
		c = webkit_web_context_new_with_website_data_manager(m);
	}
	if (sandbox) g_object_set_data(G_OBJECT(c), "lgx-sandbox", GINT_TO_POINTER(1));
	g_signal_connect(c, "download-started", G_CALLBACK(onDownload), NULL);
	webkit_web_context_set_process_model(c, WEBKIT_PROCESS_MODEL_MULTIPLE_SECONDARY_PROCESSES);
	webkit_web_context_set_cache_model(c, memTotalMB > 0 && memTotalMB <= 8192 ? WEBKIT_CACHE_MODEL_DOCUMENT_BROWSER : WEBKIT_CACHE_MODEL_WEB_BROWSER);
	if (!priv) {
		char *cookies = g_build_filename(dataDir, *profile ? profile : "default", "cookies.sqlite", NULL);
		webkit_cookie_manager_set_persistent_storage(webkit_web_context_get_cookie_manager(c), cookies, WEBKIT_COOKIE_PERSISTENT_STORAGE_SQLITE);
		g_free(cookies);
	}
	g_hash_table_insert(contexts, g_strdup(key), c);
	return c;
}

static void historyOf(LV *v, int loading) {
	lgxGoLoading(v->id, loading, webkit_web_view_can_go_back(v->web), webkit_web_view_can_go_forward(v->web));
}

static void onURI(WebKitWebView *w, GParamSpec *p, LV *v) {
	const char *u = webkit_web_view_get_uri(w);
	lgxGoURL(v->id, (char *)(u ? u : ""));
}
static void onTitle(WebKitWebView *w, GParamSpec *p, LV *v) {
	const char *t = webkit_web_view_get_title(w);
	lgxGoTitle(v->id, (char *)(t ? t : ""));
}
static void onLoad(WebKitWebView *w, WebKitLoadEvent e, LV *v) {
	if (e == WEBKIT_LOAD_STARTED) historyOf(v, 1);
	if (e == WEBKIT_LOAD_FINISHED) historyOf(v, 0);
}
static void onAudio(WebKitWebView *w, GParamSpec *p, LV *v) { lgxGoAudio(v->id, webkit_web_view_is_playing_audio(w)); }
static gboolean onFull(WebKitWebView *w, LV *v) { lgxGoFullscreen(v->id, 1); return FALSE; }
static gboolean onUnfull(WebKitWebView *w, LV *v) { lgxGoFullscreen(v->id, 0); return FALSE; }
static void onCrash(WebKitWebView *w, WebKitWebProcessTerminationReason r, LV *v) { lgxGoCrashed(v->id); }

static gboolean onDecide(WebKitWebView *w, WebKitPolicyDecision *d, WebKitPolicyDecisionType t, LV *v) {
	if (t == WEBKIT_POLICY_DECISION_TYPE_RESPONSE) {
		if (!webkit_response_policy_decision_is_mime_type_supported(WEBKIT_RESPONSE_POLICY_DECISION(d))) {
			webkit_policy_decision_download(d);
			return TRUE;
		}
		return FALSE;
	}
	if (t != WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION) return FALSE;
	WebKitNavigationAction *a = webkit_navigation_policy_decision_get_navigation_action(WEBKIT_NAVIGATION_POLICY_DECISION(d));
	const char *u = webkit_uri_request_get_uri(webkit_navigation_action_get_request(a));
	char *r = lgxGoDecide(v->id, (char *)(u ? u : ""));
	if (!r) return FALSE;
	webkit_policy_decision_ignore(d);
	if (strcmp(r, "-") != 0) webkit_web_view_load_uri(w, r);
	free(r);
	return TRUE;
}

static gboolean onFocusIn(GtkWidget *w, GdkEvent *e, LV *v) {
	lgxGoFocus(v->id);
	return FALSE;
}

static gboolean onPermission(WebKitWebView *w, WebKitPermissionRequest *r, LV *v) {
	if (!v->sandbox) return FALSE; // the engine asks as usual
	webkit_permission_request_deny(r);
	return TRUE;
}

static int vkFor(guint kv) {
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

static gboolean onKey(GtkWidget *w, GdkEventKey *e, LV *v) {
	int ctrl = (e->state & GDK_CONTROL_MASK) != 0, shift = (e->state & GDK_SHIFT_MASK) != 0, alt = (e->state & GDK_MOD1_MASK) != 0;
	int vk = vkFor(e->keyval);
	gunichar ch = gdk_keyval_to_unicode(gdk_keyval_to_lower(e->keyval));
	if (!ctrl && !alt && !vk) return FALSE;
	return lgxGoKey(v->id, (int)ch, vk, ctrl, shift, alt) ? TRUE : FALSE;
}

static void wire(LV *v);

static GtkWidget *onCreate(WebKitWebView *w, WebKitNavigationAction *a, LV *v) {
	const char *u = webkit_uri_request_get_uri(webkit_navigation_action_get_request(a));
	uintptr_t nid = lgxGoPopup(v->id, (char *)(u ? u : ""));
	if (!nid) return NULL;
	LV *n = lv(nid, 1);
	n->ucm = v->ucm;
	n->sandbox = v->sandbox;
	n->web = WEBKIT_WEB_VIEW(g_object_new(WEBKIT_TYPE_WEB_VIEW, "related-view", w, "user-content-manager", v->ucm, NULL));
	wire(n);
	return GTK_WIDGET(n->web);
}

static void wire(LV *v) {
	g_object_set_data(G_OBJECT(v->web), "lgx-view", (gpointer)v->id); // downloads find their page by it
	g_signal_connect(v->web, "notify::uri", G_CALLBACK(onURI), v);
	g_signal_connect(v->web, "notify::title", G_CALLBACK(onTitle), v);
	g_signal_connect(v->web, "load-changed", G_CALLBACK(onLoad), v);
	g_signal_connect(v->web, "notify::is-playing-audio", G_CALLBACK(onAudio), v);
	g_signal_connect(v->web, "enter-fullscreen", G_CALLBACK(onFull), v);
	g_signal_connect(v->web, "leave-fullscreen", G_CALLBACK(onUnfull), v);
	g_signal_connect(v->web, "web-process-terminated", G_CALLBACK(onCrash), v);
	g_signal_connect(v->web, "decide-policy", G_CALLBACK(onDecide), v);
	g_signal_connect(v->web, "create", G_CALLBACK(onCreate), v);
	g_signal_connect(v->web, "key-press-event", G_CALLBACK(onKey), v);
	g_signal_connect(v->web, "focus-in-event", G_CALLBACK(onFocusIn), v);
	g_signal_connect(v->web, "permission-request", G_CALLBACK(onPermission), v);
	WebKitSettings *s = webkit_web_view_get_settings(v->web);
	webkit_settings_set_enable_fullscreen(s, TRUE);
	webkit_settings_set_enable_developer_extras(s, TRUE);
	webkit_settings_set_hardware_acceleration_policy(s, WEBKIT_HARDWARE_ACCELERATION_POLICY_ALWAYS);
	webkit_settings_set_javascript_can_open_windows_automatically(s, FALSE);
	if (host) {
		// the page sits in our window, over the interface, hidden until placed
		gtk_widget_set_no_show_all(GTK_WIDGET(v->web), TRUE);
		gtk_layout_put(host, GTK_WIDGET(v->web), 0, 0);
		gtk_widget_set_size_request(GTK_WIDGET(v->web), 1, 1);
		gtk_widget_realize(GTK_WIDGET(v->web));
		return;
	}
	// the page lives in a plug window inside the Gio window
	v->plug = gtk_plug_new((Window)parentXID);
	gtk_container_add(GTK_CONTAINER(v->plug), GTK_WIDGET(v->web));
	gtk_widget_realize(v->plug);
}

typedef struct {
	int op;
	uintptr_t id, cb;
	int a, b, c, d;
	char *s;
} Op;

static void evalDone(GObject *o, GAsyncResult *r, gpointer data) {
	uintptr_t cb = (uintptr_t)data;
	GError *err = NULL;
	WebKitJavascriptResult *res = webkit_web_view_run_javascript_finish(WEBKIT_WEB_VIEW(o), r, &err);
	char *json = NULL;
	if (res) {
		JSCValue *v = webkit_javascript_result_get_js_value(res);
		json = jsc_value_to_json(v, 0);
		webkit_javascript_result_unref(res);
	}
	if (err) g_error_free(err);
	if (cb) lgxGoResult(cb, json ? json : "null");
	g_free(json);
}

static void filterSaved(GObject *o, GAsyncResult *r, gpointer data) {
	GError *err = NULL;
	WebKitUserContentFilter *f = webkit_user_content_filter_store_save_finish(WEBKIT_USER_CONTENT_FILTER_STORE(o), r, &err);
	if (!f) {
		if (err) g_error_free(err);
		return;
	}
	if (filter) webkit_user_content_filter_unref(filter);
	filter = f;
	GHashTableIter it;
	gpointer k, val;
	g_hash_table_iter_init(&it, views);
	while (g_hash_table_iter_next(&it, &k, &val)) {
		LV *v = val;
		if (v->ucm) {
			webkit_user_content_manager_remove_all_filters(v->ucm);
			webkit_user_content_manager_add_filter(v->ucm, filter);
		}
	}
}

static gboolean runOp(gpointer data) {
	Op *op = data;
	LV *v = op->id && op->op != OP_DLCANCEL ? lv(op->id, op->op == OP_SCRIPT || op->op == OP_PROFILE || op->op == OP_NEW) : NULL;
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
		WebKitDownload *d = g_hash_table_lookup(downloads, (gpointer)op->id);
		if (d) webkit_download_cancel(d);
		break;
	}
	case OP_NEW: {
		if (!v->web) {
			v->ucm = webkit_user_content_manager_new();
			for (GSList *l = v->scripts; l; l = l->next)
				webkit_user_content_manager_add_script(v->ucm, webkit_user_script_new(l->data, WEBKIT_USER_CONTENT_INJECT_ALL_FRAMES,
				                                                                       WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START, NULL, NULL));
			g_slist_free_full(v->scripts, g_free);
			v->scripts = NULL;
			if (filter) webkit_user_content_manager_add_filter(v->ucm, filter);
			v->web = WEBKIT_WEB_VIEW(g_object_new(WEBKIT_TYPE_WEB_VIEW, "web-context", contextFor(v->profile ? v->profile : "", v->priv, v->sandbox),
			                                      "user-content-manager", v->ucm, NULL));
			wire(v);
		}
		lgxGoCreated(op->cb, v->web != NULL);
		break;
	}
	case OP_BLOCKLIST: {
		char *path = g_build_filename(dataDir, "shields", NULL);
		WebKitUserContentFilterStore *st = webkit_user_content_filter_store_new(path);
		GBytes *b = g_bytes_new(op->s, strlen(op->s));
		webkit_user_content_filter_store_save(st, "litego-shields", b, NULL, filterSaved, NULL);
		g_bytes_unref(b);
		g_object_unref(st);
		g_free(path);
		break;
	}
	default:
		if (!v || !v->web) break;
		switch (op->op) {
		case OP_NAV: webkit_web_view_load_uri(v->web, op->s); break;
		case OP_BACK: webkit_web_view_go_back(v->web); break;
		case OP_FWD: webkit_web_view_go_forward(v->web); break;
		case OP_RELOAD: webkit_web_view_reload(v->web); break;
		case OP_STOP: webkit_web_view_stop_loading(v->web); break;
		case OP_BOUNDS: {
			if (host) {
				// the bounds come in device pixels; the layout counts GTK units
				int sf = gtk_widget_get_scale_factor(GTK_WIDGET(host));
				if (sf < 1) sf = 1;
				int w = op->c / sf, h = op->d / sf;
				gtk_layout_move(host, GTK_WIDGET(v->web), op->a / sf, op->b / sf);
				gtk_widget_set_size_request(GTK_WIDGET(v->web), w > 0 ? w : 1, h > 0 ? h : 1);
				break;
			}
			GdkWindow *gw = gtk_widget_get_window(v->plug);
			int w = op->c > 0 ? op->c : 1, h = op->d > 0 ? op->d : 1;
			gtk_window_resize(GTK_WINDOW(v->plug), w, h);
			if (gw) gdk_window_move_resize(gw, op->a, op->b, w, h);
			gtk_widget_set_size_request(GTK_WIDGET(v->web), op->c, op->d);
			break;
		}
		case OP_SHOW:
			if (host) {
				if (op->a) gtk_widget_show(GTK_WIDGET(v->web));
				else gtk_widget_hide(GTK_WIDGET(v->web));
				break;
			}
			if (op->a) gtk_widget_show_all(v->plug);
			else gtk_widget_hide(v->plug);
			break;
		case OP_FOCUS: gtk_widget_grab_focus(GTK_WIDGET(v->web)); break;
		case OP_EVAL: webkit_web_view_run_javascript(v->web, op->s, NULL, evalDone, (gpointer)op->cb); op->cb = 0; break;
		case OP_MUTE: webkit_web_view_set_is_muted(v->web, op->a); break;
		case OP_ZOOM: webkit_web_view_set_zoom_level(v->web, op->a / 100.0); break;
		case OP_CLOSE:
			gtk_widget_destroy(host ? GTK_WIDGET(v->web) : v->plug);
			g_hash_table_remove(views, (gpointer)op->id);
			g_free(v->profile);
			g_free(v);
			break;
		}
	}
	if (op->op == OP_EVAL && op->cb) lgxGoResult(op->cb, "null"); // no view to run it
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

static void setup(const char *dir) {
	dataDir = g_strdup(dir);
	views = g_hash_table_new(g_direct_hash, g_direct_equal);
	contexts = g_hash_table_new(g_str_hash, g_str_equal);
	downloads = g_hash_table_new_full(g_direct_hash, g_direct_equal, NULL, g_object_unref);
}

// lgxAttach starts the engine in Lite Go's GTK window (on GTK's thread).
void lgxAttach(uintptr_t layout, const char *dir) {
	if (!views) setup(dir);
	host = GTK_LAYOUT((GtkWidget *)layout);
	g_object_add_weak_pointer(G_OBJECT(host), (gpointer *)&host);
}

void lgxMain(unsigned long parent, const char *dir) {
	parentXID = parent;
	gdk_set_allowed_backends("x11");
	gtk_init(NULL, NULL);
	setup(dir);
	g_main_context_acquire(g_main_context_default());
	gtk_main();
}

char *lgxVersion(void) {
	char *s = g_strdup_printf("%u.%u.%u", webkit_get_major_version(), webkit_get_minor_version(), webkit_get_micro_version());
	char *out = strdup(s);
	g_free(s);
	return out;
}
