// The macOS side of Lite Go's web engine: WKWebView views placed inside the
// Gio window's view, reporting to Go by number. Everything here runs on the
// main thread (Gio runs window calls there).

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#include <CommonCrypto/CommonDigest.h>
#include <mach/mach.h>
#include <stdint.h>
#include <stdlib.h>

extern void lgGoURL(uintptr_t id, char *u);
extern void lgGoTitle(uintptr_t id, char *t);
extern void lgGoLoading(uintptr_t id, int on, int back, int fwd);
extern char *lgGoDecide(uintptr_t id, char *u);
extern uintptr_t lgGoPopup(uintptr_t id, uintptr_t native, char *u);
extern void lgGoFullscreen(uintptr_t id, int on);
extern void lgGoCrashed(uintptr_t id);
extern int lgGoKey(uintptr_t id, int ch, int vk, int cmd, int shift, int alt);
extern void lgGoResult(uintptr_t cb, char *res);

static NSView *lgParent;
static NSString *lgDataDir;
static WKContentRuleList *lgRules;
static NSMutableDictionary<NSString *, WKWebsiteDataStore *> *lgStores;
static NSMutableSet *lgAll;

@interface LGWebView : WKWebView
@property(nonatomic) uintptr_t lgID;
@end

@interface LGDelegate : NSObject <WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate>
@property(nonatomic, weak) LGWebView *view;
@end

static char *dupstr(NSString *s) { return strdup(s ? s.UTF8String : ""); }

static void report(LGWebView *v) {
	char *u = dupstr(v.URL.absoluteString);
	lgGoURL(v.lgID, u);
	free(u);
}

@implementation LGWebView
// browser shortcuts typed while the page has the keyboard (Cmd works as Ctrl)
- (BOOL)performKeyEquivalent:(NSEvent *)e {
	NSEventModifierFlags m = e.modifierFlags;
	int cmd = (m & (NSEventModifierFlagCommand | NSEventModifierFlagControl)) != 0;
	int shift = (m & NSEventModifierFlagShift) != 0, alt = (m & NSEventModifierFlagOption) != 0;
	NSString *c = e.charactersIgnoringModifiers;
	int ch = c.length ? [c characterAtIndex:0] : 0;
	int vk = 0;
	switch (ch) {
	case NSLeftArrowFunctionKey: vk = 0x25; break;
	case NSRightArrowFunctionKey: vk = 0x27; break;
	case NSF5FunctionKey: vk = 0x74; break;
	case NSF6FunctionKey: vk = 0x75; break;
	case NSF11FunctionKey: vk = 0x7A; break;
	case '[': if (cmd) { vk = 0x25; cmd = 0; alt = 1; } break; // Cmd+[ back
	case ']': if (cmd) { vk = 0x27; cmd = 0; alt = 1; } break;
	}
	if ((cmd || alt || vk) && lgGoKey(self.lgID, ch, vk, cmd, shift, alt)) return YES;
	return [super performKeyEquivalent:e];
}
@end

static void observe(LGWebView *v, LGDelegate *d);

@implementation LGDelegate
- (void)webView:(WKWebView *)w decidePolicyForNavigationAction:(WKNavigationAction *)a decisionHandler:(void (^)(WKNavigationActionPolicy))h {
	if (a.targetFrame && !a.targetFrame.isMainFrame) { h(WKNavigationActionPolicyAllow); return; }
	char *u = dupstr(a.request.URL.absoluteString);
	char *r = lgGoDecide(self.view.lgID, u);
	free(u);
	if (r) {
		NSString *to = [NSString stringWithUTF8String:r];
		free(r);
		h(WKNavigationActionPolicyCancel);
		if (![to isEqualToString:@"-"]) [w loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:to]]];
		return;
	}
	h(WKNavigationActionPolicyAllow);
}
- (void)webView:(WKWebView *)w decidePolicyForNavigationResponse:(WKNavigationResponse *)r decisionHandler:(void (^)(WKNavigationResponsePolicy))h {
	if (!r.canShowMIMEType) { h(WKNavigationResponsePolicyDownload); return; }
	h(WKNavigationResponsePolicyAllow);
}
- (void)webView:(WKWebView *)w navigationResponse:(WKNavigationResponse *)r didBecomeDownload:(WKDownload *)d { d.delegate = self; }
- (void)webView:(WKWebView *)w navigationAction:(WKNavigationAction *)a didBecomeDownload:(WKDownload *)d { d.delegate = self; }
- (void)download:(WKDownload *)d decideDestinationUsingResponse:(NSURLResponse *)r suggestedFilename:(NSString *)name completionHandler:(void (^)(NSURL *))h {
	NSURL *dir = [NSFileManager.defaultManager URLsForDirectory:NSDownloadsDirectory inDomains:NSUserDomainMask].firstObject;
	NSURL *to = [dir URLByAppendingPathComponent:name];
	for (int i = 1; [NSFileManager.defaultManager fileExistsAtPath:to.path] && i < 100; i++)
		to = [dir URLByAppendingPathComponent:[NSString stringWithFormat:@"%@ (%d).%@", name.stringByDeletingPathExtension, i, name.pathExtension]];
	h(to);
}
- (void)webView:(WKWebView *)w didStartProvisionalNavigation:(WKNavigation *)n { lgGoLoading(self.view.lgID, 1, w.canGoBack, w.canGoForward); }
- (void)webView:(WKWebView *)w didCommitNavigation:(WKNavigation *)n { report(self.view); }
- (void)webView:(WKWebView *)w didFinishNavigation:(WKNavigation *)n { lgGoLoading(self.view.lgID, 0, w.canGoBack, w.canGoForward); }
- (void)webView:(WKWebView *)w didFailNavigation:(WKNavigation *)n withError:(NSError *)e { lgGoLoading(self.view.lgID, 0, w.canGoBack, w.canGoForward); }
- (void)webView:(WKWebView *)w didFailProvisionalNavigation:(WKNavigation *)n withError:(NSError *)e { lgGoLoading(self.view.lgID, 0, w.canGoBack, w.canGoForward); }
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)w { lgGoCrashed(self.view.lgID); }
// window.open and target=_blank: the new view must exist now, so it is made
// here with WebKit's configuration and handed to Go
- (WKWebView *)webView:(WKWebView *)w createWebViewWithConfiguration:(WKWebViewConfiguration *)c forNavigationAction:(WKNavigationAction *)a windowFeatures:(WKWindowFeatures *)f {
	LGWebView *nv = [[LGWebView alloc] initWithFrame:NSZeroRect configuration:c];
	LGDelegate *d = [LGDelegate new];
	d.view = nv;
	nv.navigationDelegate = d;
	nv.UIDelegate = d;
	nv.hidden = YES;
	[lgParent addSubview:nv];
	[lgAll addObject:@[ nv, d ]];
	char *u = dupstr(a.request.URL.absoluteString);
	nv.lgID = lgGoPopup(self.view.lgID, (uintptr_t)(__bridge void *)nv, u);
	free(u);
	if (!nv.lgID) { [nv removeFromSuperview]; return nil; }
	observe(nv, d);
	return nv;
}
- (void)observeValueForKeyPath:(NSString *)k ofObject:(id)o change:(NSDictionary *)c context:(void *)ctx {
	LGWebView *v = self.view;
	if ([k isEqualToString:@"title"]) {
		char *t = dupstr(v.title);
		lgGoTitle(v.lgID, t);
		free(t);
	} else if ([k isEqualToString:@"URL"]) {
		report(v);
	} else if ([k isEqualToString:@"fullscreenState"]) {
		if (@available(macOS 13.0, *)) lgGoFullscreen(v.lgID, v.fullscreenState == WKFullscreenStateInFullscreen);
	}
}
@end

static void observe(LGWebView *v, LGDelegate *d) {
	[v addObserver:d forKeyPath:@"title" options:0 context:nil];
	[v addObserver:d forKeyPath:@"URL" options:0 context:nil];
	if (@available(macOS 13.0, *)) [v addObserver:d forKeyPath:@"fullscreenState" options:0 context:nil];
}

void lgStart(uintptr_t parent, const char *dataDir) {
	lgParent = (__bridge NSView *)(void *)parent;
	lgDataDir = [NSString stringWithUTF8String:dataDir];
	lgStores = [NSMutableDictionary new];
	lgAll = [NSMutableSet new];
}

void lgSetBlocklist(const char *json) {
	NSString *s = [NSString stringWithUTF8String:json];
	[WKContentRuleListStore.defaultStore compileContentRuleListForIdentifier:@"litego-shields" encodedContentRuleList:s
	                                                       completionHandler:^(WKContentRuleList *list, NSError *err) {
		if (!list) return;
		WKContentRuleList *old = lgRules;
		lgRules = list;
		for (NSArray *pair in lgAll) {
			WKUserContentController *ucc = ((WKWebView *)pair[0]).configuration.userContentController;
			if (old) [ucc removeContentRuleList:old];
			[ucc addContentRuleList:list];
		}
	}];
}

// a container's own storage: a persistent store per name (macOS 14+), a
// memory-only store for private and temporary tabs
static WKWebsiteDataStore *storeFor(NSString *profile, int priv) {
	if (priv) {
		WKWebsiteDataStore *s = lgStores[[@"private:" stringByAppendingString:profile]];
		if (!s) {
			s = WKWebsiteDataStore.nonPersistentDataStore;
			lgStores[[@"private:" stringByAppendingString:profile]] = s;
		}
		return s;
	}
	if (profile.length == 0) return WKWebsiteDataStore.defaultDataStore;
	if (@available(macOS 14.0, *)) {
		unsigned char h[CC_MD5_DIGEST_LENGTH];
		const char *p = profile.UTF8String;
		CC_MD5(p, (CC_LONG)strlen(p), h);
		h[6] = (h[6] & 0x0f) | 0x30;
		h[8] = (h[8] & 0x3f) | 0x80;
		NSUUID *u = [[NSUUID alloc] initWithUUIDBytes:h];
		return [WKWebsiteDataStore dataStoreForIdentifier:u];
	}
	return WKWebsiteDataStore.defaultDataStore;
}

uintptr_t lgNewView(uintptr_t id, const char *profile, int priv, uintptr_t popup, const char **scripts, int n) {
	WKWebViewConfiguration *c = [WKWebViewConfiguration new];
	c.websiteDataStore = storeFor([NSString stringWithUTF8String:profile], priv);
	if (@available(macOS 12.3, *)) c.preferences.elementFullscreenEnabled = YES;
	c.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
	c.preferences.javaScriptCanOpenWindowsAutomatically = NO;
	for (int i = 0; i < n; i++) {
		WKUserScript *s = [[WKUserScript alloc] initWithSource:[NSString stringWithUTF8String:scripts[i]]
		                                         injectionTime:WKUserScriptInjectionTimeAtDocumentStart
		                                      forMainFrameOnly:NO];
		[c.userContentController addUserScript:s];
	}
	if (lgRules) [c.userContentController addContentRuleList:lgRules];
	LGWebView *v = [[LGWebView alloc] initWithFrame:NSZeroRect configuration:c];
	v.lgID = id;
	v.allowsBackForwardNavigationGestures = YES;
	v.allowsMagnification = YES;
	if (@available(macOS 13.3, *)) v.inspectable = YES;
	LGDelegate *d = [LGDelegate new];
	d.view = v;
	v.navigationDelegate = d;
	v.UIDelegate = d;
	v.hidden = YES;
	[lgParent addSubview:v];
	[lgAll addObject:@[ v, d ]];
	observe(v, d);
	return (uintptr_t)(__bridge void *)v;
}

#define V ((__bridge LGWebView *)(void *)v)

void lgNavigate(uintptr_t v, const char *url) {
	NSURL *u = [NSURL URLWithString:[NSString stringWithUTF8String:url]];
	if (u) [V loadRequest:[NSURLRequest requestWithURL:u]];
}
void lgBack(uintptr_t v) { [V goBack]; }
void lgForward(uintptr_t v) { [V goForward]; }
void lgReload(uintptr_t v) { [V reload]; }
void lgStop(uintptr_t v) { [V stopLoading]; }

// x, y, w, h are physical pixels from the top left of the Gio view
void lgSetFrame(uintptr_t v, int x, int y, int w, int h) {
	CGFloat s = lgParent.window ? lgParent.window.backingScaleFactor : 1;
	NSRect b = lgParent.bounds;
	CGFloat px = x / s, py = y / s, pw = w / s, ph = h / s;
	if (!lgParent.isFlipped) py = b.size.height - py - ph;
	V.frame = NSMakeRect(px, py, pw, ph);
}
void lgSetHidden(uintptr_t v, int hidden) { V.hidden = hidden != 0; }
void lgFocus(uintptr_t v) { [V.window makeFirstResponder:V]; }

void lgEval(uintptr_t v, const char *js, uintptr_t cb) {
	[V evaluateJavaScript:[NSString stringWithUTF8String:js] completionHandler:^(id res, NSError *err) {
		if (!cb) return;
		NSString *out = @"null";
		if (res && !err) {
			if ([NSJSONSerialization isValidJSONObject:res]) {
				NSData *d = [NSJSONSerialization dataWithJSONObject:res options:0 error:nil];
				if (d) out = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
			} else if ([res isKindOfClass:NSString.class]) {
				NSData *d = [NSJSONSerialization dataWithJSONObject:@[ res ] options:0 error:nil];
				NSString *a = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
				out = [a substringWithRange:NSMakeRange(1, a.length - 2)];
			} else if ([res isKindOfClass:NSNumber.class]) {
				out = [res stringValue];
			}
		}
		char *c = dupstr(out);
		lgGoResult(cb, c);
		free(c);
	}];
}

void lgClose(uintptr_t v) {
	LGWebView *w = V;
	for (NSArray *pair in lgAll.allObjects) {
		if (pair[0] == w) {
			LGDelegate *d = pair[1];
			[w removeObserver:d forKeyPath:@"title"];
			[w removeObserver:d forKeyPath:@"URL"];
			if (@available(macOS 13.0, *)) [w removeObserver:d forKeyPath:@"fullscreenState"];
			[lgAll removeObject:pair];
		}
	}
	[w stopLoading];
	[w removeFromSuperview];
}

char *lgVersion(void) {
	NSBundle *b = [NSBundle bundleForClass:WKWebView.class];
	return dupstr([b objectForInfoDictionaryKey:@"CFBundleShortVersionString"]);
}

double lgSelfMB(void) {
	task_vm_info_data_t info;
	mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
	if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &n) != KERN_SUCCESS) return 0;
	return info.phys_footprint / 1048576.0;
}
