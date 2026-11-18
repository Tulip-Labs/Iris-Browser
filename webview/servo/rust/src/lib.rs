//! Iris's bridge to Servo: the C functions webview/servo (Go) calls, on the
//! thread Servo was started on (GTK's), and the callbacks it gets back.
//!
//! Each page has its own software rendering context: after Servo paints a
//! page, its pixels are read back and handed over (iris_servo_frame), and
//! GTK draws them one pixel on one screen pixel. Sharing the frames on the
//! graphics chip instead (dmabuf) is the next step (docs/engines.md).

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::ffi::{CStr, CString, c_char, c_void};
use std::rc::Rc;

use dpi::PhysicalSize;
use euclid::{Box2D, Point2D, Scale};
use keyboard_types::{Code, Key, KeyState, Location, Modifiers, NamedKey};
use servo::{
    CookieSource, InputEvent, KeyboardEvent, LoadStatus, MouseButton, MouseButtonAction, MouseButtonEvent,
    MouseMoveEvent, NavigationRequest, RenderingContext, Servo, ServoBuilder, SoftwareRenderingContext,
    WebResourceLoad, WebResourceResponse, WebView, WebViewBuilder, WebViewDelegate, WheelDelta, WheelEvent,
    WheelMode,
};
use url::Url;

// ---- callbacks into Iris (C, set once by iris_servo_init) ----

/// Servo has work: Iris calls iris_servo_spin on its thread soon. Any thread.
type WakeFn = extern "C" fn();
/// A page's event: kind (see EV_*), a text and two numbers.
type EventFn = extern "C" fn(id: u64, kind: i32, text: *const c_char, a: i32, b: i32);
/// A page's new frame: RGBA, premultiplied, top row first.
type FrameFn = extern "C" fn(id: u64, rgba: *const u8, w: i32, h: i32);
/// Whether a request may go out (1) or is blocked (0): Iris Shields.
type AllowFn = extern "C" fn(id: u64, url: *const c_char, page: *const c_char, kind: *const c_char) -> i32;
/// Whether the page may go to an address (1), or Iris takes it (0).
type NavigateFn = extern "C" fn(id: u64, url: *const c_char) -> i32;
/// A script's result as JSON.
type ResultFn = extern "C" fn(token: u64, json: *const c_char);

const EV_URL: i32 = 1;
const EV_TITLE: i32 = 2;
const EV_LOADING: i32 = 3; // a: 1 while loading
const EV_HISTORY: i32 = 4; // a: can go back, b: can go forward
const EV_CRASHED: i32 = 5;
const EV_NEW_TAB: i32 = 6; // text: the address a page opened in a new window
const EV_CURSOR: i32 = 7; // text: the CSS cursor name
const EV_LOADED: i32 = 8; // the page and its parts have loaded (cookies to read)
const EV_HEAD: i32 = 9; // the page's head is parsed: Iris's page scripts go in

#[derive(Clone, Copy)]
struct Callbacks {
    wake: WakeFn,
    event: EventFn,
    frame: FrameFn,
    allow: AllowFn,
    navigate: NavigateFn,
    result: ResultFn,
}

struct Page {
    webview: WebView,
    ctx: Rc<SoftwareRenderingContext>,
    dirty: Cell<bool>,
    shown: Cell<bool>,
}

struct State {
    servo: Servo,
    cb: Callbacks,
    pages: RefCell<HashMap<u64, Rc<Page>>>,
    /// pages opened by a page in a new window: their first address goes to
    /// Iris as a new tab, then they close
    probes: RefCell<Vec<(u64, WebView)>>,
    scale: Cell<f32>,
}

thread_local! {
    static STATE: RefCell<Option<Rc<State>>> = const { RefCell::new(None) };
}

fn state() -> Option<Rc<State>> {
    STATE.with(|s| s.borrow().clone())
}

fn cstr(s: &str) -> CString {
    CString::new(s.replace('\0', "")).unwrap_or_default()
}

unsafe fn from_c(p: *const c_char) -> String {
    if p.is_null() {
        return String::new();
    }
    unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned()
}

// ---- waking Iris ----

#[derive(Clone)]
struct Waker(WakeFn);

impl servo::EventLoopWaker for Waker {
    fn clone_box(&self) -> Box<dyn servo::EventLoopWaker> {
        Box::new(self.clone())
    }
    fn wake(&self) {
        (self.0)()
    }
}

// ---- what Servo reports ----

struct Delegate {
    id: u64,
    cb: Callbacks,
}

impl Delegate {
    fn emit(&self, kind: i32, text: &str, a: i32, b: i32) {
        let t = cstr(text);
        (self.cb.event)(self.id, kind, t.as_ptr(), a, b);
    }
}

fn kebab(name: &str) -> String {
    let mut out = String::new();
    for (i, c) in name.chars().enumerate() {
        if c.is_uppercase() && i > 0 {
            out.push('-');
        }
        out.extend(c.to_lowercase());
    }
    out
}

impl WebViewDelegate for Delegate {
    fn notify_url_changed(&self, _wv: WebView, url: Url) {
        self.emit(EV_URL, url.as_str(), 0, 0);
    }
    fn notify_page_title_changed(&self, _wv: WebView, title: Option<String>) {
        self.emit(EV_TITLE, title.as_deref().unwrap_or(""), 0, 0);
    }
    fn notify_load_status_changed(&self, _wv: WebView, status: LoadStatus) {
        if status == LoadStatus::HeadParsed {
            self.emit(EV_HEAD, "", 0, 0);
        }
        let loading = status != LoadStatus::Complete;
        self.emit(EV_LOADING, "", loading as i32, 0);
        if !loading {
            self.emit(EV_LOADED, "", 0, 0);
        }
    }
    fn notify_history_changed(&self, _wv: WebView, entries: Vec<Url>, current: usize) {
        self.emit(EV_HISTORY, "", (current > 0) as i32, (current + 1 < entries.len()) as i32);
    }
    fn notify_new_frame_ready(&self, _wv: WebView) {
        if let Some(st) = state() {
            if let Some(p) = st.pages.borrow().get(&self.id) {
                p.dirty.set(true);
            }
        }
    }
    fn notify_crashed(&self, _wv: WebView, reason: String, _bt: Option<String>) {
        self.emit(EV_CRASHED, &reason, 0, 0);
    }
    fn notify_cursor_changed(&self, _wv: WebView, cursor: servo::Cursor) {
        self.emit(EV_CURSOR, &kebab(&format!("{cursor:?}")), 0, 0);
    }
    fn request_navigation(&self, _wv: WebView, req: NavigationRequest) {
        let u = cstr(req.url.as_str());
        if (self.cb.navigate)(self.id, u.as_ptr()) != 0 {
            req.allow();
        } else {
            req.deny();
        }
    }
    fn request_create_new(&self, _parent: WebView, req: servo::CreateNewWebViewRequest) {
        // a link or script opening a new window: Iris opens its address in a
        // new tab, which the router gives to the right engine
        let Some(st) = state() else { return };
        let ctx: Rc<dyn RenderingContext> = match SoftwareRenderingContext::new(PhysicalSize::new(16, 16)) {
            Ok(c) => Rc::new(c),
            Err(_) => return,
        };
        let probe = Rc::new(Probe { parent: self.id, cb: self.cb, done: Cell::new(false) });
        let wv = req.builder(ctx).delegate(probe).build();
        st.probes.borrow_mut().push((self.id, wv));
    }
    fn load_web_resource(&self, wv: WebView, load: WebResourceLoad) {
        let req = load.request();
        let kind = match format!("{:?}", req.destination).to_lowercase().as_str() {
            "script" | "serviceworker" | "sharedworker" | "worker" => "script",
            "image" => "image",
            "audio" | "video" | "track" => "media",
            "document" | "iframe" | "frame" => "document",
            "style" => "stylesheet",
            "font" => "font",
            "" | "none" => "xmlhttprequest",
            _ => "other",
        };
        let page = wv.url().map(|u| u.to_string()).unwrap_or_default();
        let (u, p, k) = (cstr(req.url.as_str()), cstr(&page), cstr(kind));
        if (self.cb.allow)(self.id, u.as_ptr(), p.as_ptr(), k.as_ptr()) == 0 {
            let url = req.url.clone();
            load.intercept(WebResourceResponse::new(url)).cancel();
        }
    }
}

struct Probe {
    parent: u64,
    cb: Callbacks,
    done: Cell<bool>,
}

impl WebViewDelegate for Probe {
    fn request_navigation(&self, wv: WebView, req: NavigationRequest) {
        if self.done.replace(true) {
            req.deny();
            return;
        }
        let t = cstr(req.url.as_str());
        (self.cb.event)(self.parent, EV_NEW_TAB, t.as_ptr(), 0, 0);
        req.deny();
        if let Some(st) = state() {
            st.probes.borrow_mut().retain(|(_, w)| w.id() != wv.id());
        }
    }
}

// ---- the C functions ----

/// Starts Servo on this thread. Returns 1 when it started.
#[unsafe(no_mangle)]
pub extern "C" fn iris_servo_init(
    wake: WakeFn,
    event: EventFn,
    frame: FrameFn,
    allow: AllowFn,
    navigate: NavigateFn,
    result: ResultFn,
    scale: f32,
) -> i32 {
    if state().is_some() {
        return 1;
    }
    let _ = rustls::crypto::ring::default_provider().install_default();
    let r = std::panic::catch_unwind(|| ServoBuilder::default().event_loop_waker(Box::new(Waker(wake))).build());
    let Ok(servo) = r else { return 0 };
    servo.setup_logging();
    let st = Rc::new(State {
        servo,
        cb: Callbacks { wake, event, frame, allow, navigate, result },
        pages: RefCell::new(HashMap::new()),
        probes: RefCell::new(Vec::new()),
        scale: Cell::new(if scale > 0.0 { scale } else { 1.0 }),
    });
    STATE.with(|s| *s.borrow_mut() = Some(st));
    1
}

/// Runs Servo's pending work, then paints the pages that changed and hands
/// their frames to Iris.
#[unsafe(no_mangle)]
pub extern "C" fn iris_servo_spin() {
    let Some(st) = state() else { return };
    st.servo.spin_event_loop();
    let pages: Vec<(u64, Rc<Page>)> = st.pages.borrow().iter().map(|(k, v)| (*k, v.clone())).collect();
    for (id, p) in pages {
        if !p.dirty.replace(false) || !p.shown.get() {
            continue;
        }
        let _ = p.ctx.make_current();
        p.webview.paint();
        let size = p.ctx.size();
        let rect = Box2D::new(Point2D::zero(), Point2D::new(size.width as i32, size.height as i32));
        if let Some(img) = p.ctx.read_to_image(rect) {
            let (w, h) = (img.width() as i32, img.height() as i32);
            (st.cb.frame)(id, img.as_raw().as_ptr(), w, h);
        }
        p.ctx.present();
    }
}

/// Makes page id, w×h device pixels, showing url ("" for none).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn iris_servo_open(id: u64, w: i32, h: i32, url: *const c_char) -> i32 {
    let Some(st) = state() else { return 0 };
    let size = PhysicalSize::new(w.max(16) as u32, h.max(16) as u32);
    let ctx = match SoftwareRenderingContext::new(size) {
        Ok(c) => Rc::new(c),
        Err(_) => return 0,
    };
    let delegate = Rc::new(Delegate { id, cb: st.cb });
    let mut b = WebViewBuilder::new(&st.servo, ctx.clone())
        .delegate(delegate)
        .hidpi_scale_factor(Scale::new(st.scale.get()));
    let u = unsafe { from_c(url) };
    if let Ok(parsed) = Url::parse(&u) {
        b = b.url(parsed);
    }
    let webview = b.build();
    st.pages.borrow_mut().insert(id, Rc::new(Page { webview, ctx, dirty: Cell::new(true), shown: Cell::new(true) }));
    1
}

fn with_page(id: u64, f: impl FnOnce(&Page)) {
    if let Some(st) = state() {
        let p = st.pages.borrow().get(&id).cloned();
        if let Some(p) = p {
            f(&p);
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn iris_servo_close(id: u64) {
    if let Some(st) = state() {
        let p = st.pages.borrow_mut().remove(&id);
        drop(p); // the last handle: Servo closes the page
        st.probes.borrow_mut().retain(|(parent, _)| *parent != id);
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn iris_servo_load(id: u64, url: *const c_char) {
    let u = unsafe { from_c(url) };
    if let Ok(parsed) = Url::parse(&u) {
        with_page(id, |p| p.webview.load(parsed));
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn iris_servo_back(id: u64) {
    with_page(id, |p| {
        if p.webview.can_go_back() {
            p.webview.go_back(1);
        }
    });
}

#[unsafe(no_mangle)]
pub extern "C" fn iris_servo_forward(id: u64) {
    with_page(id, |p| {
        if p.webview.can_go_forward() {
            p.webview.go_forward(1);
        }
    });
}

#[unsafe(no_mangle)]
pub extern "C" fn iris_servo_reload(id: u64) {
    with_page(id, |p| p.webview.reload());
}

#[unsafe(no_mangle)]
pub extern "C" fn iris_servo_resize(id: u64, w: i32, h: i32) {
    with_page(id, |p| {
        let size = PhysicalSize::new(w.max(16) as u32, h.max(16) as u32);
        if p.ctx.size() != size {
            p.ctx.resize(size);
            p.webview.resize(size);
            p.dirty.set(true);
        }
    });
}

#[unsafe(no_mangle)]
pub extern "C" fn iris_servo_show(id: u64, on: i32) {
    with_page(id, |p| {
        p.shown.set(on != 0);
        if on != 0 {
            p.webview.show();
            p.webview.set_throttled(false);
            p.dirty.set(true);
        } else {
            p.webview.hide();
            p.webview.set_throttled(true);
        }
    });
}

#[unsafe(no_mangle)]
pub extern "C" fn iris_servo_focus(id: u64, on: i32) {
    with_page(id, |p| if on != 0 { p.webview.focus() } else { p.webview.blur() });
}

#[unsafe(no_mangle)]
pub extern "C" fn iris_servo_zoom(id: u64, z: f32) {
    with_page(id, |p| p.webview.set_page_zoom(z));
}

/// The pointer moved to (x, y), in the page's device pixels.
#[unsafe(no_mangle)]
pub extern "C" fn iris_servo_mouse_move(id: u64, x: f32, y: f32) {
    with_page(id, |p| {
        p.webview.notify_input_event(InputEvent::MouseMove(MouseMoveEvent::new(servo::DevicePoint::new(x, y).into())));
    });
}

/// A button (1 left, 2 middle, 3 right) went down (down=1) or up at (x, y).
#[unsafe(no_mangle)]
pub extern "C" fn iris_servo_mouse_button(id: u64, x: f32, y: f32, button: i32, down: i32) {
    let b = match button {
        2 => MouseButton::Middle,
        3 => MouseButton::Right,
        _ => MouseButton::Left,
    };
    let action = if down != 0 { MouseButtonAction::Down } else { MouseButtonAction::Up };
    with_page(id, |p| {
        p.webview
            .notify_input_event(InputEvent::MouseButton(MouseButtonEvent::new(action, b, servo::DevicePoint::new(x, y).into())));
    });
}

/// The wheel or the touchpad at (x, y): (dx, dy) in pixels (pixels=1) or lines.
#[unsafe(no_mangle)]
pub extern "C" fn iris_servo_wheel(id: u64, x: f32, y: f32, dx: f64, dy: f64, pixels: i32) {
    let mode = if pixels != 0 { WheelMode::DeltaPixel } else { WheelMode::DeltaLine };
    with_page(id, |p| {
        let delta = WheelDelta { x: dx as _, y: dy as _, z: 0 as _, mode };
        p.webview.notify_input_event(InputEvent::Wheel(WheelEvent::new(delta, servo::DevicePoint::new(x, y).into())));
    });
}

/// A key: its DOM key value ("a", "Enter", "ArrowLeft"…) and code
/// ("KeyA"…, "" when unknown), down=1 or up, mods: 1 shift, 2 ctrl, 4 alt,
/// 8 meta.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn iris_servo_key(id: u64, key: *const c_char, code: *const c_char, down: i32, mods: i32, repeat: i32) {
    let (k, c) = unsafe { (from_c(key), from_c(code)) };
    let key = match k.parse::<NamedKey>() {
        Ok(n) if k.chars().count() > 1 => Key::Named(n),
        _ => Key::Character(k),
    };
    let code = c.parse::<Code>().unwrap_or(Code::Unidentified);
    let mut m = Modifiers::empty();
    if mods & 1 != 0 {
        m |= Modifiers::SHIFT;
    }
    if mods & 2 != 0 {
        m |= Modifiers::CONTROL;
    }
    if mods & 4 != 0 {
        m |= Modifiers::ALT;
    }
    if mods & 8 != 0 {
        m |= Modifiers::META;
    }
    let state = if down != 0 { KeyState::Down } else { KeyState::Up };
    with_page(id, |p| {
        let ev = KeyboardEvent::new_without_event(state, key, code, Location::Standard, m, repeat != 0, false);
        p.webview.notify_input_event(InputEvent::Keyboard(ev));
    });
}

/// JSON with Servo's own wrapping removed ({"String":"a"} is "a").
fn plain(v: serde_json::Value) -> serde_json::Value {
    use serde_json::Value;
    match v {
        Value::String(s) if s == "Undefined" || s == "Null" => Value::Null,
        Value::Object(m) if m.len() == 1 => {
            let (k, inner) = m.into_iter().next().unwrap();
            if k.chars().next().is_some_and(|c| c.is_uppercase()) {
                plain(inner)
            } else {
                Value::Object([(k, plain(inner))].into_iter().collect())
            }
        }
        Value::Object(m) => Value::Object(m.into_iter().map(|(k, v)| (k, plain(v))).collect()),
        Value::Array(a) => Value::Array(a.into_iter().map(plain).collect()),
        other => other,
    }
}

/// Runs js in the page; its result arrives through the result callback with
/// token ("null" when it failed).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn iris_servo_eval(id: u64, js: *const c_char, token: u64) {
    let script = unsafe { from_c(js) };
    let Some(st) = state() else { return };
    let cb = st.cb.result;
    let p = st.pages.borrow().get(&id).cloned();
    let Some(p) = p else {
        let n = cstr("null");
        cb(token, n.as_ptr());
        return;
    };
    p.webview.evaluate_javascript(script, move |r| {
        let json = match r {
            Ok(v) => serde_json::to_value(&v).map(plain).map(|v| v.to_string()).unwrap_or_else(|_| "null".into()),
            Err(_) => "null".into(),
        };
        let j = cstr(&json);
        cb(token, j.as_ptr());
    });
}

/// The cookies Servo has for address url, as Set-Cookie lines separated by
/// newlines (free with iris_servo_free).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn iris_servo_cookies(url: *const c_char) -> *mut c_char {
    let u = unsafe { from_c(url) };
    let Some(st) = state() else { return std::ptr::null_mut() };
    let Ok(parsed) = Url::parse(&u) else { return std::ptr::null_mut() };
    let lines: Vec<String> =
        st.servo.site_data_manager().cookies_for_url(parsed, CookieSource::HTTP).iter().map(|c| c.to_string()).collect();
    cstr(&lines.join("\n")).into_raw()
}

/// Gives Servo a cookie (a Set-Cookie line) for address url.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn iris_servo_set_cookie(url: *const c_char, line: *const c_char) {
    let (u, l) = unsafe { (from_c(url), from_c(line)) };
    let Some(st) = state() else { return };
    let (Ok(parsed), Ok(c)) = (Url::parse(&u), cookie::Cookie::parse(l)) else { return };
    st.servo.site_data_manager().set_cookie_for_url(parsed, c.into_owned(), None);
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn iris_servo_free(p: *mut c_char) {
    if !p.is_null() {
        drop(unsafe { CString::from_raw(p) });
    }
}

/// The scale new pages start at (device pixels per CSS pixel).
#[unsafe(no_mangle)]
pub extern "C" fn iris_servo_set_scale(scale: f32) {
    if let Some(st) = state() {
        if scale > 0.0 {
            st.scale.set(scale);
            for p in st.pages.borrow().values() {
                p.webview.set_hidpi_scale_factor(Scale::new(scale));
            }
        }
    }
}

#[allow(dead_code)]
fn _unused(_: *mut c_void) {}
