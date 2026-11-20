//go:build linux && webkit

// The Linux side of Iris's main web engine: WebKitGTK 6 (GTK 4).
//
// Each page is a WebKitWebView, a real GTK widget and a child of Iris's
// view (cmd/iris/gtk_linux.c), placed over the interface where the tab's
// page goes. GTK draws it at the screen's own scale, on the graphics chip,
// and gives it the pointer, the wheel, touch and the keys itself; Iris only
// keeps its shortcuts (Ctrl+T, Ctrl+L...) and draws its menus over it.
//
// Everything here runs on GTK's thread. Go's calls from other threads come
// through lwkOnMain.

#define _GNU_SOURCE
#include <gtk/gtk.h>
#include <webkit/webkit.h>
#include <libsoup/soup.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// Go (engine_webkit.go)
extern void lwkGoURL(uintptr_t id, char *u);
extern void lwkGoTitle(uintptr_t id, char *t);
extern void lwkGoLoading(uintptr_t id, int on, int back, int fwd);
extern int lwkGoDecide(uintptr_t id, char *u, int newWindow, int userLink, int middle);
extern void lwkGoNewWindow(uintptr_t id, char *u, uintptr_t popup);
extern void lwkGoFullscreen(uintptr_t id, int on);
extern void lwkGoCrashed(uintptr_t id);
extern void lwkGoFailed(uintptr_t id, char *u, int code);
extern void lwkGoAudio(uintptr_t id, int on);
extern int lwkGoKey(uintptr_t id, int ch, int vk, int ctrl, int shift, int alt);
extern void lwkGoResult(uintptr_t token, char *json);
extern void lwkGoFocus(uintptr_t id);
extern void lwkGoDownload(uintptr_t n, uintptr_t view, int state, char *url, char *path, long long total, long long got);
extern void lwkGoCookies(int jar, char *lines);
extern void lwkGoRun(uintptr_t h);
extern void lwkGoFilterReady(int ok);

enum { DL_ACTIVE = 0, DL_DONE = 2, DL_FAILED = 3, DL_CANCELED = 4 };

// ---- the window ----

static GtkWidget *host;   // Iris's view: the pages are its children
static char *dataDir;     // Iris's data folder
static int overlayUp;     // Iris draws a menu over the pages: they take no input

typedef struct {
	uintptr_t id;
	WebKitWebView *web;
	int jar;      // index into jars
	int sandbox;  // no downloads, no permissions
	int shown;
	int x, y, w, h; // in the screen's pixels
	char *going;  // the address Iris itself asked for (not asked about again)
	char *deferred; // an address waiting for the jar's cookies from Iris
} WV;

static GHashTable *views; // id -> WV*

// ---- sessions: one per cookie jar ----
//
// The default jar, each container, private tabs (in memory) and sandbox tabs
// (in memory, never shared) each have a network session of their own.

typedef struct {
	char *name;
	WebKitNetworkSession *s;
	WebKitCookieManager *cm;
	guint sync; // a cookie report is waiting
	int bridged;
	int adding; // cookies from Iris still being added: pages wait to load
} Jar;

static GPtrArray *jars;
static WebKitUserContentFilter *filter;
static GPtrArray *scripts; // char*
static int strictTracking;

static char *jarDir(const char *kind, const char *name) {
	char *safe = g_uri_escape_string(name[0] ? name : "default", NULL, FALSE);
	char *p = g_build_filename(dataDir, "webkit", kind, safe, NULL);
	g_free(safe);
	return p;
}

static void onDownloadStarted(WebKitNetworkSession *s, WebKitDownload *d, gpointer data);
static void onCookiesChanged(WebKitCookieManager *cm, gpointer data);

// lwkJar returns the index of the jar named name, making its session the
// first time. Memory-only jars (private, sandbox) keep nothing on disk.
int lwkJar(const char *name, int memory, int bridged) {
	if (!jars) jars = g_ptr_array_new();
	for (guint i = 0; i < jars->len; i++) {
		Jar *j = g_ptr_array_index(jars, i);
		if (strcmp(j->name, name) == 0) return (int)i;
	}
	Jar *j = g_new0(Jar, 1);
	j->name = g_strdup(name);
	j->bridged = bridged;
	if (memory) {
		j->s = webkit_network_session_new_ephemeral();
	} else {
		char *data = jarDir("data", name), *cache = jarDir("cache", name);
		j->s = webkit_network_session_new(data, cache);
		char *db = g_build_filename(data, "cookies.sqlite", NULL);
		webkit_cookie_manager_set_persistent_storage(webkit_network_session_get_cookie_manager(j->s), db,
		                                             WEBKIT_COOKIE_PERSISTENT_STORAGE_SQLITE);
		g_free(db);
		g_free(data);
		g_free(cache);
	}
	j->cm = webkit_network_session_get_cookie_manager(j->s);
	webkit_network_session_set_itp_enabled(j->s, strictTracking);
	g_signal_connect(j->s, "download-started", G_CALLBACK(onDownloadStarted), GINT_TO_POINTER(memory && strcmp(name, "sandbox") == 0));
	g_ptr_array_add(jars, j);
	int idx = (int)jars->len - 1;
	if (bridged) g_signal_connect(j->cm, "changed", G_CALLBACK(onCookiesChanged), GINT_TO_POINTER(idx));
	return idx;
}

void lwkStrict(int on) {
	strictTracking = on;
	for (guint i = 0; jars && i < jars->len; i++) webkit_network_session_set_itp_enabled(((Jar *)g_ptr_array_index(jars, i))->s, on);
}

// ---- the cookie bridge ----
//
// WebKit tells that a jar changed, not what: a moment later Iris reads the
// whole jar and Go reports the differences to the shared store
// (core/session). Cookies from Electron come back through lwkSetCookie.

static void gotCookies(GObject *o, GAsyncResult *r, gpointer data) {
	int idx = GPOINTER_TO_INT(data);
	GList *list = webkit_cookie_manager_get_all_cookies_finish(WEBKIT_COOKIE_MANAGER(o), r, NULL);
	GString *b = g_string_new(NULL);
	for (GList *l = list; l; l = l->next) {
		SoupCookie *c = l->data;
		GDateTime *exp = soup_cookie_get_expires(c);
		const char *dom = soup_cookie_get_domain(c);
		const char *ss = "";
		switch (soup_cookie_get_same_site_policy(c)) {
		case SOUP_SAME_SITE_POLICY_LAX: ss = "Lax"; break;
		case SOUP_SAME_SITE_POLICY_STRICT: ss = "Strict"; break;
		default: ss = "None"; break;
		}
		// name, value, domain, host only, path, expires, secure, http only, same site
		g_string_append_printf(b, "%s\t%s\t%s\t%d\t%s\t%lld\t%d\t%d\t%s\n", soup_cookie_get_name(c), soup_cookie_get_value(c),
		                       dom && dom[0] == '.' ? dom + 1 : (dom ? dom : ""), !(dom && dom[0] == '.'), soup_cookie_get_path(c),
		                       exp ? (long long)g_date_time_to_unix(exp) : 0LL, soup_cookie_get_secure(c), soup_cookie_get_http_only(c), ss);
	}
	g_list_free_full(list, (GDestroyNotify)soup_cookie_free);
	lwkGoCookies(idx, b->str);
	g_string_free(b, TRUE);
}

static gboolean readJar(gpointer data) {
	int idx = GPOINTER_TO_INT(data);
	Jar *j = g_ptr_array_index(jars, idx);
	j->sync = 0;
	webkit_cookie_manager_get_all_cookies(j->cm, NULL, gotCookies, data);
	return G_SOURCE_REMOVE;
}

static void onCookiesChanged(WebKitCookieManager *cm, gpointer data) {
	Jar *j = g_ptr_array_index(jars, GPOINTER_TO_INT(data));
	if (!j->sync) j->sync = g_timeout_add(300, readJar, data);
}

// lwkReadJar reports jar idx to Go now (a session's first look).
void lwkReadJar(int idx) { readJar(GINT_TO_POINTER(idx)); }

static void loadNow(WV *v, const char *u);

// added: one cookie from Iris is in; when the last is, the pages that waited
// for them load
static void added(GObject *o, GAsyncResult *r, gpointer data) {
	webkit_cookie_manager_add_cookie_finish(WEBKIT_COOKIE_MANAGER(o), r, NULL);
	int idx = GPOINTER_TO_INT(data);
	Jar *j = g_ptr_array_index(jars, idx);
	if (--j->adding > 0 || !views) return;
	GHashTableIter it;
	gpointer k, val;
	g_hash_table_iter_init(&it, views);
	while (g_hash_table_iter_next(&it, &k, &val)) {
		WV *v = val;
		if (v->jar == idx && v->deferred) {
			char *u = v->deferred;
			v->deferred = NULL;
			loadNow(v, u);
			g_free(u);
		}
	}
}

// lwkSetCookie gives a cookie from the shared store to jar idx (or takes it
// away). expires is Unix seconds, 0 for a session cookie.
void lwkSetCookie(int idx, const char *name, const char *value, const char *domain, int hostOnly, const char *path,
                  long long expires, int secure, int httpOnly, const char *sameSite, int removed) {
	if (!jars || idx < 0 || idx >= (int)jars->len) return;
	Jar *j = g_ptr_array_index(jars, idx);
	char *dom = hostOnly ? g_strdup(domain) : g_strconcat(".", domain, NULL);
	SoupCookie *c = soup_cookie_new(name, value, dom, path && *path ? path : "/", -1);
	g_free(dom);
	if (expires > 0) {
		GDateTime *t = g_date_time_new_from_unix_utc(expires);
		soup_cookie_set_expires(c, t);
		g_date_time_unref(t);
	}
	soup_cookie_set_secure(c, secure);
	soup_cookie_set_http_only(c, httpOnly);
	// SameSite=None needs Secure; an unset one is Lax, as in browsers
	if (sameSite && strcmp(sameSite, "Strict") == 0) soup_cookie_set_same_site_policy(c, SOUP_SAME_SITE_POLICY_STRICT);
	else if (sameSite && strcmp(sameSite, "None") == 0 && secure) soup_cookie_set_same_site_policy(c, SOUP_SAME_SITE_POLICY_NONE);
	else soup_cookie_set_same_site_policy(c, SOUP_SAME_SITE_POLICY_LAX);
	if (removed) {
		webkit_cookie_manager_delete_cookie(j->cm, c, NULL, NULL, NULL);
	} else {
		j->adding++;
		webkit_cookie_manager_add_cookie(j->cm, c, NULL, added, GINT_TO_POINTER(idx));
	}
	soup_cookie_free(c);
}

// ---- the shield: WebKit's content blockers ----

static gint64 compiling; // when the last compile started

// lwkSetRules gives every page the shield's rules (JSON) under id (a hash of
// them): the compiled list WebKit kept on disk when it has one, else it
// compiles them (a few seconds, off the window's thread) and drops the
// older lists.
typedef struct {
	char *id, *json;
	int n;
} RulesJob;

static WebKitUserContentFilterStore *filterStore(void) {
	static WebKitUserContentFilterStore *st;
	if (!st) {
		char *dir = g_build_filename(dataDir, "webkit", "shields", NULL);
		st = webkit_user_content_filter_store_new(dir);
		g_free(dir);
	}
	return st;
}

static void gotIDs(GObject *o, GAsyncResult *r, gpointer keep) {
	char **ids = webkit_user_content_filter_store_fetch_identifiers_finish(WEBKIT_USER_CONTENT_FILTER_STORE(o), r);
	for (int i = 0; ids && ids[i]; i++)
		if (strcmp(ids[i], keep) != 0) webkit_user_content_filter_store_remove(filterStore(), ids[i], NULL, NULL, NULL);
	g_strfreev(ids);
	g_free(keep);
}

static void useFilter(WebKitUserContentFilter *f) {
	if (filter) webkit_user_content_filter_unref(filter);
	filter = f;
	GHashTableIter it;
	gpointer k, val;
	g_hash_table_iter_init(&it, views);
	while (g_hash_table_iter_next(&it, &k, &val)) {
		WebKitUserContentManager *ucm = webkit_web_view_get_user_content_manager(((WV *)val)->web);
		webkit_user_content_manager_remove_all_filters(ucm);
		webkit_user_content_manager_add_filter(ucm, filter);
	}
	webkit_user_content_filter_store_fetch_identifiers(filterStore(), NULL, gotIDs, g_strdup(webkit_user_content_filter_get_identifier(f)));
	lwkGoFilterReady(1);
}

static void compiled(GObject *o, GAsyncResult *r, gpointer data) {
	GError *err = NULL;
	WebKitUserContentFilter *f = webkit_user_content_filter_store_save_finish(WEBKIT_USER_CONTENT_FILTER_STORE(o), r, &err);
	if (!f) {
		g_printerr("Iris: the shield's rules did not compile: %s\n", err ? err->message : "?");
		g_clear_error(&err);
		lwkGoFilterReady(0);
		return;
	}
	if (g_getenv("IRIS_GL_DEBUG")) g_printerr("Iris: the shield's rules compiled for WebKit in %.1f s\n", (g_get_monotonic_time() - compiling) / 1e6);
	useFilter(f);
}

static void loaded(GObject *o, GAsyncResult *r, gpointer data) {
	RulesJob *job = data;
	WebKitUserContentFilter *f = webkit_user_content_filter_store_load_finish(WEBKIT_USER_CONTENT_FILTER_STORE(o), r, NULL);
	if (f) {
		useFilter(f);
	} else {
		GBytes *b = g_bytes_new(job->json, job->n);
		compiling = g_get_monotonic_time();
		webkit_user_content_filter_store_save(filterStore(), job->id, b, NULL, compiled, NULL);
		g_bytes_unref(b);
	}
	g_free(job->id);
	g_free(job->json);
	g_free(job);
}

void lwkSetRules(const char *json, int n, const char *id) {
	RulesJob *job = g_new0(RulesJob, 1);
	job->id = g_strdup(id);
	job->json = g_memdup2(json, n);
	job->n = n;
	webkit_user_content_filter_store_load(filterStore(), id, NULL, loaded, job);
}

// lwkSetScripts replaces the scripts that run in every page before its own.
void lwkSetScripts(char **list, int n) {
	if (scripts) g_ptr_array_free(scripts, TRUE);
	scripts = g_ptr_array_new_with_free_func(g_free);
	for (int i = 0; i < n; i++) g_ptr_array_add(scripts, g_strdup(list[i]));
}

static void addScripts(WebKitUserContentManager *ucm) {
	for (guint i = 0; scripts && i < scripts->len; i++) {
		WebKitUserScript *s = webkit_user_script_new(g_ptr_array_index(scripts, i), WEBKIT_USER_CONTENT_INJECT_TOP_FRAME,
		                                             WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START, NULL, NULL);
		webkit_user_content_manager_add_script(ucm, s);
		webkit_user_script_unref(s);
	}
}

// ---- downloads ----

static GHashTable *downloads; // n -> WebKitDownload*
static uintptr_t lastDownload;

static uintptr_t viewIDOf(WebKitWebView *web) {
	if (!web || !views) return 0;
	GHashTableIter it;
	gpointer k, v;
	g_hash_table_iter_init(&it, views);
	while (g_hash_table_iter_next(&it, &k, &v))
		if (((WV *)v)->web == web) return ((WV *)v)->id;
	return 0;
}

static void dlReport(WebKitDownload *d, int state) {
	uintptr_t n = (uintptr_t)g_object_get_data(G_OBJECT(d), "iris-n");
	const char *dest = webkit_download_get_destination(d);
	char *path = dest ? (g_str_has_prefix(dest, "file://") ? g_filename_from_uri(dest, NULL, NULL) : g_strdup(dest)) : g_strdup("");
	WebKitURIResponse *resp = webkit_download_get_response(d);
	long long total = resp ? (long long)webkit_uri_response_get_content_length(resp) : -1;
	if (total <= 0) total = -1;
	WebKitURIRequest *req = webkit_download_get_request(d);
	lwkGoDownload(n, viewIDOf(webkit_download_get_web_view(d)), state, (char *)(req ? webkit_uri_request_get_uri(req) : ""), path, total,
	              (long long)webkit_download_get_received_data_length(d));
	g_free(path);
}

static gboolean dlDecide(WebKitDownload *d, const char *suggested, gpointer data) {
	const char *dir = g_get_user_special_dir(G_USER_DIRECTORY_DOWNLOAD);
	if (!dir) dir = g_get_home_dir();
	char *base = g_path_get_basename(suggested && *suggested ? suggested : "download");
	char *p = g_build_filename(dir, base, NULL);
	for (int i = 1; g_file_test(p, G_FILE_TEST_EXISTS) && i < 1000; i++) {
		g_free(p);
		const char *dot = strrchr(base, '.');
		char *stem = dot && dot != base ? g_strndup(base, dot - base) : g_strdup(base);
		char *name = g_strdup_printf("%s (%d)%s", stem, i, dot && dot != base ? dot : "");
		p = g_build_filename(dir, name, NULL);
		g_free(stem);
		g_free(name);
	}
	webkit_download_set_destination(d, p);
	g_free(p);
	g_free(base);
	dlReport(d, DL_ACTIVE);
	return TRUE;
}

static void dlProgress(WebKitDownload *d, GParamSpec *ps, gpointer data) { dlReport(d, DL_ACTIVE); }
static void dlFinished(WebKitDownload *d, gpointer data) {
	if (!g_object_get_data(G_OBJECT(d), "iris-failed")) dlReport(d, DL_DONE);
	g_hash_table_remove(downloads, g_object_get_data(G_OBJECT(d), "iris-n"));
}
static void dlFailed(WebKitDownload *d, GError *err, gpointer data) {
	g_object_set_data(G_OBJECT(d), "iris-failed", GINT_TO_POINTER(1));
	dlReport(d, g_error_matches(err, WEBKIT_DOWNLOAD_ERROR, WEBKIT_DOWNLOAD_ERROR_CANCELLED_BY_USER) ? DL_CANCELED : DL_FAILED);
}

static void onDownloadStarted(WebKitNetworkSession *s, WebKitDownload *d, gpointer sandbox) {
	if (GPOINTER_TO_INT(sandbox)) { // a sandbox downloads nothing
		webkit_download_cancel(d);
		return;
	}
	if (!downloads) downloads = g_hash_table_new_full(g_direct_hash, g_direct_equal, NULL, g_object_unref);
	uintptr_t n = ++lastDownload;
	g_object_set_data(G_OBJECT(d), "iris-n", (gpointer)n);
	g_hash_table_insert(downloads, (gpointer)n, g_object_ref(d));
	g_signal_connect(d, "decide-destination", G_CALLBACK(dlDecide), NULL);
	g_signal_connect(d, "notify::estimated-progress", G_CALLBACK(dlProgress), NULL);
	g_signal_connect(d, "finished", G_CALLBACK(dlFinished), NULL);
	g_signal_connect(d, "failed", G_CALLBACK(dlFailed), NULL);
}

void lwkCancelDownload(uintptr_t n) {
	WebKitDownload *d = downloads ? g_hash_table_lookup(downloads, (gpointer)n) : NULL;
	if (d) webkit_download_cancel(d);
}

// ---- a page's events ----

static void onURI(WebKitWebView *web, GParamSpec *ps, WV *v) {
	const char *u = webkit_web_view_get_uri(web);
	lwkGoURL(v->id, (char *)(u ? u : ""));
}

static void onTitle(WebKitWebView *web, GParamSpec *ps, WV *v) {
	const char *t = webkit_web_view_get_title(web);
	lwkGoTitle(v->id, (char *)(t ? t : ""));
}

static void history(WV *v, int loading) {
	lwkGoLoading(v->id, loading, webkit_web_view_can_go_back(v->web), webkit_web_view_can_go_forward(v->web));
}

static void onLoad(WebKitWebView *web, WebKitLoadEvent ev, WV *v) {
	history(v, ev != WEBKIT_LOAD_FINISHED);
	if (ev == WEBKIT_LOAD_COMMITTED) g_clear_pointer(&v->going, g_free);
}

static void onBackForward(WebKitBackForwardList *l, WebKitBackForwardListItem *added, gpointer removed, WV *v) {
	history(v, webkit_web_view_is_loading(v->web));
}

static gboolean onFailed(WebKitWebView *web, WebKitLoadEvent ev, const char *uri, GError *err, WV *v) {
	if (g_error_matches(err, WEBKIT_NETWORK_ERROR, WEBKIT_NETWORK_ERROR_CANCELLED) ||
	    g_error_matches(err, WEBKIT_POLICY_ERROR, WEBKIT_POLICY_ERROR_FRAME_LOAD_INTERRUPTED_BY_POLICY_CHANGE) ||
	    g_error_matches(err, WEBKIT_MEDIA_ERROR, WEBKIT_MEDIA_ERROR_WILL_HANDLE_LOAD))
		return FALSE;
	lwkGoFailed(v->id, (char *)(uri ? uri : ""), err ? err->code : 0);
	return FALSE; // WebKit's own error page
}

static void onCrash(WebKitWebView *web, WebKitWebProcessTerminationReason why, WV *v) { lwkGoCrashed(v->id); }

static void onAudio(WebKitWebView *web, GParamSpec *ps, WV *v) { lwkGoAudio(v->id, webkit_web_view_is_playing_audio(web)); }

static gboolean onEnterFull(WebKitWebView *web, WV *v) {
	lwkGoFullscreen(v->id, 1);
	return TRUE; // Iris makes the window and the page full screen itself
}
static gboolean onLeaveFull(WebKitWebView *web, WV *v) {
	lwkGoFullscreen(v->id, 0);
	return TRUE;
}

static gboolean onPermission(WebKitWebView *web, WebKitPermissionRequest *r, WV *v) {
	// what a page needs to work, and nothing that reaches the camera, the
	// microphone, the location or notifications (as in the Electron engine)
	if (!v->sandbox && (WEBKIT_IS_POINTER_LOCK_PERMISSION_REQUEST(r) || WEBKIT_IS_WEBSITE_DATA_ACCESS_PERMISSION_REQUEST(r) ||
	                    WEBKIT_IS_CLIPBOARD_PERMISSION_REQUEST(r)))
		webkit_permission_request_allow(r);
	else
		webkit_permission_request_deny(r);
	return TRUE;
}

static gboolean onDecide(WebKitWebView *web, WebKitPolicyDecision *d, WebKitPolicyDecisionType type, WV *v) {
	if (type == WEBKIT_POLICY_DECISION_TYPE_RESPONSE) {
		WebKitResponsePolicyDecision *rd = WEBKIT_RESPONSE_POLICY_DECISION(d);
		WebKitURIResponse *resp = webkit_response_policy_decision_get_response(rd);
		guint status = resp ? webkit_uri_response_get_status_code(resp) : 0;
		// a file the page cannot show is downloaded (an error page is shown)
		if (webkit_response_policy_decision_is_main_frame_main_resource(rd) && !webkit_response_policy_decision_is_mime_type_supported(rd) &&
		    (status == 0 || status < 400)) {
			webkit_policy_decision_download(d);
			return TRUE;
		}
		return FALSE;
	}
	WebKitNavigationAction *a = webkit_navigation_policy_decision_get_navigation_action(WEBKIT_NAVIGATION_POLICY_DECISION(d));
	WebKitURIRequest *req = webkit_navigation_action_get_request(a);
	const char *u = req ? webkit_uri_request_get_uri(req) : NULL;
	if (!u) return FALSE;
	if (type == WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION && !webkit_navigation_action_is_redirect(a) && v->going &&
	    strcmp(v->going, u) == 0)
		return FALSE; // Iris asked for this one
	int link = webkit_navigation_action_get_navigation_type(a) == WEBKIT_NAVIGATION_TYPE_LINK_CLICKED;
	int middle = link && (webkit_navigation_action_get_mouse_button(a) == 2 ||
	                      (webkit_navigation_action_get_modifiers(a) & GDK_CONTROL_MASK));
	// Go answers: 0 go on, 1 stop (Go did something else with it)
	if (lwkGoDecide(v->id, (char *)u, type == WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION, link, middle)) {
		webkit_policy_decision_ignore(d);
		return TRUE;
	}
	return FALSE;
}

// a page opened a window (window.open, a sign-in pop-up): a page of the same
// session, kept for Iris's new tab, so window.opener goes on working
static GtkWidget *onCreate(WebKitWebView *web, WebKitNavigationAction *a, WV *v) {
	WebKitURIRequest *req = webkit_navigation_action_get_request(a);
	const char *u = req ? webkit_uri_request_get_uri(req) : "";
	WebKitWebView *pop = WEBKIT_WEB_VIEW(g_object_new(WEBKIT_TYPE_WEB_VIEW, "related-view", web, NULL));
	g_object_ref_sink(pop);
	lwkGoNewWindow(v->id, (char *)(u ? u : ""), (uintptr_t)pop);
	return GTK_WIDGET(pop);
}

// ---- keys: Iris's shortcuts first ----

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

static gboolean onKey(GtkEventControllerKey *c, guint kv, guint code, GdkModifierType state, WV *v) {
	int ctrl = (state & GDK_CONTROL_MASK) != 0, shift = (state & GDK_SHIFT_MASK) != 0, alt = (state & GDK_ALT_MASK) != 0;
	int vk = shortcutVK(kv);
	if (!ctrl && !alt && !vk) return FALSE;
	gunichar lc = gdk_keyval_to_unicode(gdk_keyval_to_lower(kv));
	return lwkGoKey(v->id, (int)lc, vk, ctrl, shift, alt) ? TRUE : FALSE;
}

static void onFocusIn(GtkEventControllerFocus *c, WV *v) { lwkGoFocus(v->id); }

// ---- placing the pages ----

extern double lgwScale(void) __attribute__((weak));
static double scale(void) { return lgwScale ? lgwScale() : (host ? gtk_widget_get_scale_factor(host) : 1); }

// lwkAllocate is called by Iris's view when it lays out: each shown page in
// its place. The place is in the screen's pixels; a page starts on a whole
// pixel of the screen whatever the scale (a fractional offset in the view's
// units, through a transform).
void lwkAllocate(void) {
	if (!views) return;
	double s = scale();
	GHashTableIter it;
	gpointer k, val;
	g_hash_table_iter_init(&it, views);
	while (g_hash_table_iter_next(&it, &k, &val)) {
		WV *v = val;
		if (!gtk_widget_get_visible(GTK_WIDGET(v->web))) continue;
		int w = (int)ceil(v->w / s - 0.01), h = (int)ceil(v->h / s - 0.01);
		if (w < 1) w = 1;
		if (h < 1) h = 1;
		int mw = 0, mh = 0;
		gtk_widget_measure(GTK_WIDGET(v->web), GTK_ORIENTATION_HORIZONTAL, -1, &mw, NULL, NULL, NULL);
		gtk_widget_measure(GTK_WIDGET(v->web), GTK_ORIENTATION_VERTICAL, w, &mh, NULL, NULL, NULL);
		GskTransform *t = gsk_transform_translate(NULL, &GRAPHENE_POINT_INIT((float)(v->x / s), (float)(v->y / s)));
		gtk_widget_allocate(GTK_WIDGET(v->web), MAX(w, mw), MAX(h, mh), -1, t);
	}
}

// lwkSnapshotPages draws the shown pages, over the interface.
void lwkSnapshotPages(GtkSnapshot *sn, double s) {
	if (!views || !host) return;
	GHashTableIter it;
	gpointer k, val;
	g_hash_table_iter_init(&it, views);
	while (g_hash_table_iter_next(&it, &k, &val)) {
		WV *v = val;
		if (!v->shown || !gtk_widget_get_visible(GTK_WIDGET(v->web))) continue;
		// a page has rounded corners like the glass around it (none full screen)
		graphene_rect_t r = GRAPHENE_RECT_INIT(v->x / s, v->y / s, v->w / s, v->h / s);
		GskRoundedRect rr;
		gsk_rounded_rect_init_from_rect(&rr, &r, v->x == 0 && v->y == 0 ? 0 : 12);
		gtk_snapshot_push_rounded_clip(sn, &rr);
		gtk_widget_snapshot_child(host, GTK_WIDGET(v->web), sn);
		gtk_snapshot_pop(sn);
	}
}

// lwkPagePointer says whether (x, y), in the view's units, is over a shown
// page: GTK gives such events to the page itself.
int lwkPagePointer(GdkEvent *e, double x, double y) {
	if (!views || overlayUp) return 0;
	double s = scale();
	GHashTableIter it;
	gpointer k, val;
	g_hash_table_iter_init(&it, views);
	while (g_hash_table_iter_next(&it, &k, &val)) {
		WV *v = val;
		if (v->shown && x * s >= v->x && y * s >= v->y && x * s < v->x + v->w && y * s < v->y + v->h) return 1;
	}
	return 0;
}

// lwkOverlay: while Iris's menu is over the pages, they take no pointer.
void lwkOverlay(int on) {
	overlayUp = on;
	if (!views) return;
	GHashTableIter it;
	gpointer k, val;
	g_hash_table_iter_init(&it, views);
	while (g_hash_table_iter_next(&it, &k, &val)) gtk_widget_set_can_target(GTK_WIDGET(((WV *)val)->web), !on);
}

// lwkUIFocus: the interface took the keyboard.
void lwkUIFocus(void) {}

// ---- views ----

static WebKitSettings *settingsFor(int sandbox) {
	WebKitSettings *s = webkit_settings_new();
	webkit_settings_set_enable_developer_extras(s, !sandbox);
	webkit_settings_set_javascript_can_open_windows_automatically(s, FALSE);
	webkit_settings_set_enable_back_forward_navigation_gestures(s, TRUE);
	webkit_settings_set_enable_smooth_scrolling(s, TRUE);
	webkit_settings_set_media_playback_requires_user_gesture(s, FALSE);
	webkit_settings_set_enable_webrtc(s, !sandbox);
	webkit_settings_set_enable_media_stream(s, FALSE);
	// the pages' console on Iris's output, to find problems (and for CI)
	webkit_settings_set_enable_write_console_messages_to_stdout(s, g_getenv("IRIS_GL_DEBUG") != NULL);
	return s;
}

static void connect(WV *v) {
	WebKitWebView *web = v->web;
	g_signal_connect(web, "notify::uri", G_CALLBACK(onURI), v);
	g_signal_connect(web, "notify::title", G_CALLBACK(onTitle), v);
	g_signal_connect(web, "notify::is-playing-audio", G_CALLBACK(onAudio), v);
	g_signal_connect(web, "load-changed", G_CALLBACK(onLoad), v);
	g_signal_connect(web, "load-failed", G_CALLBACK(onFailed), v);
	g_signal_connect(web, "web-process-terminated", G_CALLBACK(onCrash), v);
	g_signal_connect(web, "enter-fullscreen", G_CALLBACK(onEnterFull), v);
	g_signal_connect(web, "leave-fullscreen", G_CALLBACK(onLeaveFull), v);
	g_signal_connect(web, "permission-request", G_CALLBACK(onPermission), v);
	g_signal_connect(web, "decide-policy", G_CALLBACK(onDecide), v);
	g_signal_connect(web, "create", G_CALLBACK(onCreate), v);
	g_signal_connect(webkit_web_view_get_back_forward_list(web), "changed", G_CALLBACK(onBackForward), v);
	GtkEventController *keys = gtk_event_controller_key_new();
	gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE);
	g_signal_connect(keys, "key-pressed", G_CALLBACK(onKey), v);
	gtk_widget_add_controller(GTK_WIDGET(web), keys);
	GtkEventController *focus = gtk_event_controller_focus_new();
	g_signal_connect(focus, "enter", G_CALLBACK(onFocusIn), v);
	gtk_widget_add_controller(GTK_WIDGET(web), focus);
}

// lwkOpen makes page id in jar, or adopts popup (a page another page
// opened). It starts hidden; Go places and shows it.
int lwkOpen(uintptr_t id, int jar, int sandbox, uintptr_t popup) {
	if (!host || !jars || jar < 0 || jar >= (int)jars->len) return 0;
	if (!views) views = g_hash_table_new(g_direct_hash, g_direct_equal);
	WV *v = g_new0(WV, 1);
	v->id = id;
	v->jar = jar;
	v->sandbox = sandbox;
	if (popup) {
		v->web = WEBKIT_WEB_VIEW((gpointer)popup); // already referenced (onCreate)
	} else {
		WebKitUserContentManager *ucm = webkit_user_content_manager_new();
		WebKitSettings *st = settingsFor(sandbox);
		v->web = WEBKIT_WEB_VIEW(g_object_new(WEBKIT_TYPE_WEB_VIEW, "network-session", ((Jar *)g_ptr_array_index(jars, jar))->s,
		                                      "user-content-manager", ucm, "settings", st, NULL));
		g_object_ref_sink(v->web);
		g_object_unref(st);
		g_object_unref(ucm);
	}
	WebKitUserContentManager *ucm = webkit_web_view_get_user_content_manager(v->web);
	if (!popup) {
		addScripts(ucm);
		if (filter) webkit_user_content_manager_add_filter(ucm, filter);
	}
	connect(v);
	gtk_widget_set_visible(GTK_WIDGET(v->web), FALSE);
	gtk_widget_set_can_target(GTK_WIDGET(v->web), !overlayUp);
	gtk_widget_set_parent(GTK_WIDGET(v->web), host);
	g_hash_table_insert(views, (gpointer)id, v);
	return 1;
}

static WV *get(uintptr_t id) { return views ? g_hash_table_lookup(views, (gpointer)id) : NULL; }

static void loadNow(WV *v, const char *u) {
	g_free(v->going);
	v->going = g_strdup(u);
	webkit_web_view_load_uri(v->web, u);
}

void lwkNavigate(uintptr_t id, const char *u) {
	WV *v = get(id);
	if (!v) return;
	if (((Jar *)g_ptr_array_index(jars, v->jar))->adding > 0) { // a sign-in from Electron first
		g_free(v->deferred);
		v->deferred = g_strdup(u);
		return;
	}
	loadNow(v, u);
}

void lwkBack(uintptr_t id) { WV *v = get(id); if (v) webkit_web_view_go_back(v->web); }
void lwkForward(uintptr_t id) { WV *v = get(id); if (v) webkit_web_view_go_forward(v->web); }
void lwkReload(uintptr_t id) { WV *v = get(id); if (v) webkit_web_view_reload(v->web); }
void lwkStop(uintptr_t id) { WV *v = get(id); if (v) webkit_web_view_stop_loading(v->web); }
void lwkMute(uintptr_t id, int on) { WV *v = get(id); if (v) webkit_web_view_set_is_muted(v->web, on); }
void lwkZoom(uintptr_t id, double f) { WV *v = get(id); if (v) webkit_web_view_set_zoom_level(v->web, f); }

void lwkBounds(uintptr_t id, int x, int y, int w, int h) {
	WV *v = get(id);
	if (!v || (v->x == x && v->y == y && v->w == w && v->h == h)) return;
	v->x = x, v->y = y, v->w = w, v->h = h;
	gtk_widget_queue_allocate(host);
}

void lwkShow(uintptr_t id, int on) {
	WV *v = get(id);
	if (!v || v->shown == on) return;
	v->shown = on;
	gtk_widget_set_visible(GTK_WIDGET(v->web), on);
	gtk_widget_queue_allocate(host);
	gtk_widget_queue_draw(host);
}

void lwkFocus(uintptr_t id) {
	WV *v = get(id);
	if (v) gtk_widget_grab_focus(GTK_WIDGET(v->web));
}

static void evaluated(GObject *o, GAsyncResult *r, gpointer token) {
	JSCValue *val = webkit_web_view_evaluate_javascript_finish(WEBKIT_WEB_VIEW(o), r, NULL);
	char *json = NULL;
	if (val) {
		if (!jsc_value_is_undefined(val)) json = jsc_value_to_json(val, 0);
		g_object_unref(val);
	}
	if (token) lwkGoResult((uintptr_t)token, json ? json : "null");
	g_free(json);
}

// lwkRun evaluates js in page id; token (0: none) gets the result as JSON.
void lwkRun(uintptr_t id, const char *js, uintptr_t token) {
	WV *v = get(id);
	if (!v) {
		if (token) lwkGoResult(token, "null");
		return;
	}
	webkit_web_view_evaluate_javascript(v->web, js, -1, NULL, NULL, NULL, evaluated, (gpointer)token);
}

void lwkClose(uintptr_t id) {
	WV *v = get(id);
	if (!v) return;
	g_hash_table_remove(views, (gpointer)id);
	g_signal_handlers_disconnect_by_data(v->web, v);
	g_signal_handlers_disconnect_by_data(webkit_web_view_get_back_forward_list(v->web), v);
	webkit_web_view_try_close(v->web);
	gtk_widget_unparent(GTK_WIDGET(v->web));
	g_object_unref(v->web);
	g_free(v->going);
	g_free(v->deferred);
	g_free(v);
	gtk_widget_queue_draw(host);
}

// lwkDrop lets go of a pop-up page nobody adopted.
void lwkDrop(uintptr_t popup) {
	if (popup) g_object_unref((gpointer)popup);
}

// ---- start ----

static gboolean runGo(gpointer h) {
	lwkGoRun((uintptr_t)h);
	return G_SOURCE_REMOVE;
}
void lwkOnMain(uintptr_t h) { g_main_context_invoke(NULL, runGo, (gpointer)h); }

// lwkSandboxWorks says whether WebKit's page processes can be put in their
// sandbox (bubblewrap) here. Where user namespaces are not allowed (some
// distributions and containers) WebKit cannot start a page at all, and its
// failure would take Iris down with it: Iris then leaves WebKit out and
// Electron draws every page. Inside Flatpak, WebKit uses Flatpak's sandbox.
int lwkSandboxWorks(void) {
	if (g_getenv("FLATPAK_ID")) return 1;
	char *bw = g_find_program_in_path("bwrap");
	if (!bw) return 1; // WebKit built without its bubblewrap sandbox
	char *argv[] = {bw, "--ro-bind", "/", "/", "--proc", "/proc", "--dev", "/dev", "--unshare-all", "true", NULL};
	int status = 1;
	gboolean ran = g_spawn_sync(NULL, argv, NULL, G_SPAWN_STDOUT_TO_DEV_NULL | G_SPAWN_STDERR_TO_DEV_NULL, NULL, NULL, NULL, NULL, &status, NULL);
	g_free(bw);
	return ran && g_spawn_check_wait_status(status, NULL);
}

void lwkStart(uintptr_t view, const char *dir) {
	host = GTK_WIDGET((gpointer)view);
	dataDir = g_strdup(dir);
	if (!views) views = g_hash_table_new(g_direct_hash, g_direct_equal);
}

// lwkVersion is WebKitGTK's version, as "2.54.2".
char *lwkVersion(void) {
	return g_strdup_printf("%u.%u.%u", webkit_get_major_version(), webkit_get_minor_version(), webkit_get_micro_version());
}

// lwkMemoryKB is the resident memory of WebKit's own processes (pages,
// network, graphics): children of Iris named WebKit*.
long lwkMemoryKB(void) {
	long total = 0;
	GDir *d = g_dir_open("/proc", 0, NULL);
	if (!d) return 0;
	const char *n;
	char me[32];
	g_snprintf(me, sizeof me, "%d", getpid());
	while ((n = g_dir_read_name(d))) {
		if (n[0] < '0' || n[0] > '9') continue;
		char *p = g_build_filename("/proc", n, "status", NULL), *txt = NULL;
		if (g_file_get_contents(p, &txt, NULL, NULL)) {
			char *name = strstr(txt, "Name:\t"), *pp = strstr(txt, "PPid:\t"), *rss = strstr(txt, "VmRSS:");
			if (name && pp && rss && g_str_has_prefix(name + 6, "WebKit")) {
				char ppid[32] = {0};
				sscanf(pp + 6, "%31s", ppid);
				if (strcmp(ppid, me) == 0) total += strtol(rss + 6, NULL, 10);
			}
		}
		g_free(txt);
		g_free(p);
	}
	g_dir_close(d);
	return total;
}
