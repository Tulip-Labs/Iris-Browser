// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//
// The Android side of Lite Go's web engine: the system WebView (Android's own
// Chromium, kept up to date by the system) placed over Lite Go's Gio window.
//
// Go drives it through op() with the same operations as the other engines;
// every operation runs on the UI thread. Events go back to Go through the
// native methods, which Go exports (webview/engine_android.go).
//
// Built into webview/litego_android.jar by build-litego.sh, which gogio then
// packs into the app.

package org.tulipanlabs.litego;

import android.app.Activity;
import android.app.DownloadManager;
import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.net.Uri;
import android.os.Environment;
import android.os.Handler;
import android.os.Looper;
import android.os.Message;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowInsets;
import android.view.WindowInsetsController;
import android.webkit.CookieManager;
import android.webkit.DownloadListener;
import android.webkit.RenderProcessGoneDetail;
import android.webkit.URLUtil;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;

import java.io.ByteArrayInputStream;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.Map;

public final class LiteWeb {
	static final int OP_NEW = 1, OP_NAV = 2, OP_BACK = 3, OP_FWD = 4, OP_RELOAD = 5, OP_STOP = 6, OP_BOUNDS = 7, OP_SHOW = 8,
	                 OP_FOCUS = 9, OP_EVAL = 10, OP_MUTE = 11, OP_CLOSE = 12, OP_SCRIPT = 13, OP_PROFILE = 14, OP_PRIVATE = 15,
	                 OP_BLOCKLIST = 16, OP_SLEEP = 17, OP_WAKE = 18;

	// events, handled in Go
	static native void created(long cb, boolean ok);
	static native void url(long id, String u);
	static native void title(long id, String t);
	static native void loading(long id, boolean on, boolean back, boolean fwd);
	static native String decide(long id, String u);
	static native long popup(long id, String u);
	static native void fullscreen(long id, boolean on);
	static native void crashed(long id);
	static native void result(long cb, String json);
	static native boolean allow(long id, String u, String page, String kind);
	static native void failed(long id, String u, int status);
	static native boolean back();

	static final Handler main = new Handler(Looper.getMainLooper());
	static final HashMap<Long, Tab> tabs = new HashMap<Long, Tab>();
	static ViewGroup root;
	static View gio;
	static Context ctx;
	static boolean low;

	// a page and what was set for it before it existed
	static final class Tab {
		long id;
		WebView web;
		ArrayList<String> scripts = new ArrayList<String>();
		String profile = "";
		boolean priv;
		volatile String page = ""; // the page's address, for the shield (read off the UI thread)
		Message opener;            // a popup's pending transport
		View custom;               // a video in fullscreen
		WebChromeClient.CustomViewCallback customDone;
	}

	// start places the engine in the window of the Gio view (on the UI thread).
	public static void start(View view, boolean lowMemory) {
		gio = view;
		ctx = view.getContext();
		low = lowMemory;
		root = (ViewGroup) view.getParent();
		CookieManager.getInstance().setAcceptCookie(true);
	}

	public static String version() {
		try {
			android.content.pm.PackageInfo p = WebView.getCurrentWebViewPackage();
			if (p != null) return p.versionName;
		} catch (Throwable t) {
		}
		return "";
	}

	// op runs one operation from Go on the UI thread.
	public static void op(final int op, final long id, final int a, final int b, final int c, final int d, final String s, final long cb) {
		if (Looper.myLooper() == Looper.getMainLooper()) {
			run(op, id, a, b, c, d, s, cb);
			return;
		}
		main.post(new Runnable() {
			public void run() { LiteWeb.run(op, id, a, b, c, d, s, cb); }
		});
	}

	static Tab tab(long id, boolean make) {
		Tab t = tabs.get(id);
		if (t == null && make) {
			t = new Tab();
			t.id = id;
			tabs.put(id, t);
		}
		return t;
	}

	static void run(int op, long id, int a, int b, int c, int d, String s, final long cb) {
		Tab t = tab(id, op == OP_SCRIPT || op == OP_PROFILE || op == OP_NEW);
		switch (op) {
		case OP_SCRIPT:
			t.scripts.add(s);
			return;
		case OP_PROFILE:
			t.profile = s == null ? "" : s;
			t.priv = a != 0;
			return;
		case OP_NEW:
			if (t.web == null) make(t, null);
			created(cb, t.web != null);
			return;
		case OP_BLOCKLIST:
			return; // the shield asks about every request here
		}
		if (t == null || t.web == null) {
			if (op == OP_EVAL && cb != 0) result(cb, "null");
			return;
		}
		WebView w = t.web;
		switch (op) {
		case OP_NAV: w.loadUrl(s); break;
		case OP_BACK: if (w.canGoBack()) w.goBack(); break;
		case OP_FWD: if (w.canGoForward()) w.goForward(); break;
		case OP_RELOAD: w.reload(); break;
		case OP_STOP: w.stopLoading(); break;
		case OP_BOUNDS: {
			FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(Math.max(c, 1), Math.max(d, 1));
			lp.leftMargin = a;
			lp.topMargin = b;
			w.setLayoutParams(lp);
			break;
		}
		case OP_SHOW:
			w.setVisibility(a != 0 ? View.VISIBLE : View.INVISIBLE);
			if (a != 0) w.onResume();
			break;
		case OP_SLEEP: w.onPause(); break; // stops its timers and media; the page stays
		case OP_WAKE: w.onResume(); break;
		case OP_FOCUS: w.requestFocus(); break;
		case OP_EVAL:
			w.evaluateJavascript(s, cb == 0 ? null : new ValueCallback<String>() {
				public void onReceiveValue(String v) { result(cb, v == null ? "null" : v); }
			});
			break;
		case OP_MUTE:
			// WebView has no mute: pausing media is the closest
			if (a != 0) w.evaluateJavascript("document.querySelectorAll('video,audio').forEach(function(m){m.muted=true})", null);
			else w.evaluateJavascript("document.querySelectorAll('video,audio').forEach(function(m){m.muted=false})", null);
			break;
		case OP_CLOSE:
			if (t.custom != null) hideCustom(t);
			root.removeView(w);
			w.stopLoading();
			w.destroy();
			tabs.remove(id);
			break;
		}
	}

	// make creates the tab's WebView over the Gio view, hidden until placed.
	static void make(final Tab t, WebView opener) {
		final WebView w = new WebView(ctx);
		t.web = w;
		w.setBackgroundColor(Color.WHITE);
		w.setVisibility(View.INVISIBLE);
		WebSettings s = w.getSettings();
		s.setJavaScriptEnabled(true);
		s.setDomStorageEnabled(true);
		s.setDatabaseEnabled(true);
		s.setLoadWithOverviewMode(true);
		s.setUseWideViewPort(true);
		s.setSupportZoom(true);
		s.setBuiltInZoomControls(true);
		s.setDisplayZoomControls(false);
		s.setMediaPlaybackRequiresUserGesture(true);
		s.setSupportMultipleWindows(true);
		s.setJavaScriptCanOpenWindowsAutomatically(false);
		s.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
		s.setAllowFileAccess(false);
		s.setAllowContentAccess(false);
		s.setSafeBrowsingEnabled(false); // Lite Shields does this job, without sending addresses away
		if (t.priv) {
			s.setCacheMode(WebSettings.LOAD_NO_CACHE);
			CookieManager.getInstance().setAcceptThirdPartyCookies(w, false);
		} else {
			CookieManager.getInstance().setAcceptThirdPartyCookies(w, true);
		}
		// pages draw on the GPU in their own layer
		w.setLayerType(View.LAYER_TYPE_HARDWARE, null);
		w.setWebViewClient(new Client(t));
		w.setWebChromeClient(new Chrome(t));
		w.setDownloadListener(new DownloadListener() {
			public void onDownloadStart(String u, String agent, String disposition, String mime, long length) { download(u, agent, disposition, mime); }
		});
		w.setOnKeyListener(new View.OnKeyListener() {
			public boolean onKey(View v, int code, KeyEvent e) {
				// the system back button, while the page has the focus
				if (code == KeyEvent.KEYCODE_BACK && e.getAction() == KeyEvent.ACTION_UP) return back();
				return code == KeyEvent.KEYCODE_BACK;
			}
		});
		FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(1, 1);
		root.addView(w, lp);
	}

	static void download(String u, String agent, String disposition, String mime) {
		try {
			DownloadManager.Request r = new DownloadManager.Request(Uri.parse(u));
			String name = URLUtil.guessFileName(u, disposition, mime);
			r.setMimeType(mime);
			String cookies = CookieManager.getInstance().getCookie(u);
			if (cookies != null) r.addRequestHeader("Cookie", cookies);
			r.addRequestHeader("User-Agent", agent);
			r.setTitle(name);
			r.setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED);
			r.setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, name);
			((DownloadManager) ctx.getSystemService(Context.DOWNLOAD_SERVICE)).enqueue(r);
		} catch (Throwable e) {
		}
	}

	static void history(Tab t, boolean on) {
		loading(t.id, on, t.web.canGoBack(), t.web.canGoForward());
	}

	// what a request loads, from its address and what it accepts
	static String kindOf(WebResourceRequest r) {
		String p = r.getUrl().getPath();
		p = p == null ? "" : p.toLowerCase();
		Map<String, String> h = r.getRequestHeaders();
		String acc = h == null ? null : h.get("Accept");
		acc = acc == null ? "" : acc;
		if (p.endsWith(".css") || acc.startsWith("text/css")) return "stylesheet";
		if (p.endsWith(".woff") || p.endsWith(".woff2") || p.endsWith(".ttf") || p.endsWith(".otf")) return "font";
		if (p.endsWith(".js") || p.endsWith(".mjs")) return "script";
		if (acc.startsWith("image/") || p.endsWith(".png") || p.endsWith(".jpg") || p.endsWith(".jpeg") || p.endsWith(".gif") ||
		    p.endsWith(".webp") || p.endsWith(".svg") || p.endsWith(".avif") || p.endsWith(".ico"))
			return "image";
		if (p.endsWith(".mp4") || p.endsWith(".webm") || p.endsWith(".m3u8") || p.endsWith(".mp3") || p.endsWith(".m4s")) return "media";
		if (acc.contains("application/json")) return "xmlhttprequest";
		return "other";
	}

	static final class Client extends WebViewClient {
		final Tab t;
		Client(Tab t) { this.t = t; }

		@Override public boolean shouldOverrideUrlLoading(WebView v, WebResourceRequest r) {
			String u = r.getUrl().toString();
			String s = u.toLowerCase();
			if (!s.startsWith("http:") && !s.startsWith("https:") && !s.startsWith("about:") && !s.startsWith("data:")) {
				// another app's link (intent:, tel:, mailto:, market:)
				try {
					android.content.Intent i = s.startsWith("intent:") ? android.content.Intent.parseUri(u, android.content.Intent.URI_INTENT_SCHEME)
					                                                   : new android.content.Intent(android.content.Intent.ACTION_VIEW, Uri.parse(u));
					i.addCategory(android.content.Intent.CATEGORY_BROWSABLE);
					i.setComponent(null);
					i.setSelector(null);
					ctx.startActivity(i);
				} catch (Throwable e) {
				}
				return true;
			}
			if (!r.isForMainFrame()) return false;
			String to = decide(t.id, u);
			if (to == null) return false;
			if (!to.equals("-")) v.loadUrl(to);
			return true;
		}

		@Override public void onPageStarted(WebView v, String u, Bitmap icon) {
			t.page = u;
			url(t.id, u);
			history(t, true);
			// the scripts that must run before the page's own (best effort:
			// WebView has no document-start hook without AndroidX)
			for (String s : t.scripts) v.evaluateJavascript(s, null);
		}

		@Override public void onPageCommitVisible(WebView v, String u) {
			for (String s : t.scripts) v.evaluateJavascript(s, null);
		}

		@Override public void onPageFinished(WebView v, String u) {
			history(t, false);
		}

		@Override public void doUpdateVisitedHistory(WebView v, String u, boolean reload) {
			t.page = u;
			url(t.id, u);
			history(t, v.getProgress() < 100);
		}

		@Override public WebResourceResponse shouldInterceptRequest(WebView v, WebResourceRequest r) {
			if (r.isForMainFrame()) return null;
			String u = r.getUrl().toString();
			if (!u.startsWith("http")) return null;
			String kind = kindOf(r);
			if (kind.equals("stylesheet") || kind.equals("font")) return null; // never: pages must look right
			if (allow(t.id, u, t.page, kind)) return null;
			return new WebResourceResponse("text/plain", "utf-8", 403, "Blocked", new HashMap<String, String>(), new ByteArrayInputStream(new byte[0]));
		}

		@Override public void onReceivedHttpError(WebView v, WebResourceRequest r, WebResourceResponse e) {
			if (r.isForMainFrame()) failed(t.id, r.getUrl().toString(), e.getStatusCode());
		}

		@Override public boolean onRenderProcessGone(WebView v, RenderProcessGoneDetail d) {
			// the page's process ended (out of memory, or crashed): Lite Go offers a reload
			root.removeView(v);
			v.destroy();
			t.web = null;
			crashed(t.id);
			return true;
		}
	}

	static final class Chrome extends WebChromeClient {
		final Tab t;
		Chrome(Tab t) { this.t = t; }

		@Override public void onReceivedTitle(WebView v, String title) { LiteWeb.title(t.id, title == null ? "" : title); }

		@Override public boolean onCreateWindow(WebView v, boolean dialog, boolean gesture, Message msg) {
			if (!gesture) return false; // no popups the person did not ask for
			WebView.HitTestResult h = v.getHitTestResult();
			String u = h != null && h.getExtra() != null ? h.getExtra() : "";
			long nid = popup(t.id, u);
			if (nid == 0) return false;
			Tab n = tab(nid, true);
			n.scripts = t.scripts;
			n.priv = t.priv;
			n.profile = t.profile;
			make(n, v);
			WebView.WebViewTransport tr = (WebView.WebViewTransport) msg.obj;
			tr.setWebView(n.web);
			msg.sendToTarget();
			return true;
		}

		@Override public void onCloseWindow(WebView v) {}

		@Override public void onShowCustomView(View view, CustomViewCallback cb) {
			// a video in fullscreen: over everything, with the system bars hidden
			if (t.custom != null) hideCustom(t);
			t.custom = view;
			t.customDone = cb;
			view.setBackgroundColor(Color.BLACK);
			root.addView(view, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
			bars(false);
			fullscreen(t.id, true);
		}

		@Override public void onHideCustomView() {
			if (t.custom != null) hideCustom(t);
		}

		@Override public Bitmap getDefaultVideoPoster() {
			return Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888); // no grey play-button poster
		}
	}

	static void hideCustom(Tab t) {
		View v = t.custom;
		t.custom = null;
		root.removeView(v);
		if (t.customDone != null) t.customDone.onCustomViewHidden();
		t.customDone = null;
		bars(true);
		fullscreen(t.id, false);
	}

	// exitFullscreen leaves a fullscreen video (the back button); true if one was showing.
	public static boolean exitFullscreen() {
		for (Tab t : tabs.values()) {
			if (t.custom != null) {
				hideCustom(t);
				return true;
			}
		}
		return false;
	}

	static void bars(boolean show) {
		if (!(ctx instanceof Activity)) return;
		android.view.Window w = ((Activity) ctx).getWindow();
		if (android.os.Build.VERSION.SDK_INT >= 30) {
			WindowInsetsController c = w.getInsetsController();
			if (c == null) return;
			if (show) c.show(WindowInsets.Type.systemBars());
			else {
				c.hide(WindowInsets.Type.systemBars());
				c.setSystemBarsBehavior(WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
			}
		} else {
			w.getDecorView().setSystemUiVisibility(show ? 0
			                                            : View.SYSTEM_UI_FLAG_FULLSCREEN | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION |
			                                                  View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY);
		}
	}

	// focusApp gives the keyboard back to Lite Go's own view.
	public static void focusApp() {
		if (gio != null) gio.requestFocus();
	}

	// toBack sends Lite Go behind the other apps (back on the first page).
	public static void toBack() {
		if (ctx instanceof Activity) ((Activity) ctx).moveTaskToBack(true);
	}

	// trim gives memory back when the system asks (Lite Go's memory plan).
	public static void trim() {
		for (Tab t : tabs.values()) {
			if (t.web != null && t.web.getVisibility() != View.VISIBLE) {
				t.web.onPause();
			}
		}
	}
}
