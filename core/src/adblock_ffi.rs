//! adblock-rust behind a C interface.
//!
//! A *builder* collects filter lists and resources; `iris_adblock_build`
//! turns it into an *engine*, which is immutable and can be asked from any
//! thread (CEF's IO threads) at once. A new list means a new engine; the
//! caller swaps pointers and destroys the old one later.

use crate::{from_c, from_raw, to_buf, to_c};
use adblock::lists::{FilterSet, ParseOptions};
use adblock::request::Request;
use adblock::resources::Resource;
use adblock::Engine;
use std::collections::HashSet;
use std::ffi::c_char;

pub struct IrisAdblockBuilder {
    set: FilterSet,
    resources: Vec<Resource>,
    lists: u32,
}

pub struct IrisAdblock {
    engine: Engine,
}

const _: fn() = || {
    fn sync<T: Send + Sync>() {}
    sync::<IrisAdblock>();
};

#[no_mangle]
pub extern "C" fn iris_adblock_builder_create() -> *mut IrisAdblockBuilder {
    Box::into_raw(Box::new(IrisAdblockBuilder { set: FilterSet::new(false), resources: Vec::new(), lists: 0 }))
}

/// # Safety
/// `b` is null or from `iris_adblock_builder_create`, destroyed once.
#[no_mangle]
pub unsafe extern "C" fn iris_adblock_builder_destroy(b: *mut IrisAdblockBuilder) {
    if !b.is_null() {
        drop(Box::from_raw(b));
    }
}

/// adds a filter list (uBlock/Adblock Plus syntax, UTF-8); false if the
/// text is not UTF-8 or an argument is null
///
/// # Safety
/// `b` is a live builder; `text` points at `len` readable bytes.
#[no_mangle]
pub unsafe extern "C" fn iris_adblock_builder_add_list(b: *mut IrisAdblockBuilder, text: *const u8, len: usize) -> bool {
    let Some(b) = b.as_mut() else { return false };
    let Some(bytes) = from_raw(text, len) else { return false };
    let Ok(s) = std::str::from_utf8(bytes) else { return false };
    b.set.add_filter_list(s, ParseOptions::default());
    b.lists += 1;
    true
}

/// sets the scriptlets and redirect resources (a JSON array of adblock-rust
/// resources, as Brave's adblock-resources publishes it); false if it does
/// not parse
///
/// # Safety
/// `b` is a live builder; `json` points at `len` readable bytes.
#[no_mangle]
pub unsafe extern "C" fn iris_adblock_builder_set_resources(b: *mut IrisAdblockBuilder, json: *const u8, len: usize) -> bool {
    let Some(b) = b.as_mut() else { return false };
    let Some(bytes) = from_raw(json, len) else { return false };
    match serde_json::from_slice::<Vec<Resource>>(bytes) {
        Ok(r) => {
            b.resources = r;
            true
        }
        Err(_) => false,
    }
}

/// the engine for what the builder holds (the builder stays, empty of its
/// lists); null if no list was added
///
/// # Safety
/// `b` is a live builder.
#[no_mangle]
pub unsafe extern "C" fn iris_adblock_build(b: *mut IrisAdblockBuilder) -> *mut IrisAdblock {
    let Some(b) = b.as_mut() else { return std::ptr::null_mut() };
    if b.lists == 0 {
        return std::ptr::null_mut();
    }
    let set = std::mem::replace(&mut b.set, FilterSet::new(false));
    b.lists = 0;
    let mut engine = Engine::from_filter_set(set, true);
    if !b.resources.is_empty() {
        engine.use_resources(std::mem::take(&mut b.resources));
    }
    Box::into_raw(Box::new(IrisAdblock { engine }))
}

/// # Safety
/// `e` is null or from `iris_adblock_build`/`_deserialize`, destroyed once.
#[no_mangle]
pub unsafe extern "C" fn iris_adblock_destroy(e: *mut IrisAdblock) {
    if !e.is_null() {
        drop(Box::from_raw(e));
    }
}

pub const IRIS_ALLOW: u32 = 0;
pub const IRIS_BLOCK: u32 = 1;
/// answer with `payload` (a resource's body) instead
pub const IRIS_REDIRECT: u32 = 2;
/// load `payload` (the address without the parameters a rule removes)
pub const IRIS_REWRITE: u32 = 3;

#[repr(C)]
pub struct IrisVerdict {
    pub action: u32,
    /// a string for the caller (`iris_string_free`), or null
    pub payload: *mut c_char,
}

/// what to do with a request. `request_type` is adblock-rust's name for it
/// ("document", "subdocument", "script", "stylesheet", "image", "font",
/// "media", "xhr", "fetch", "ping", "other"...). false only for a null or
/// invalid argument or an address that is not one (then allow).
///
/// # Safety
/// `e` is live; the strings are NUL-terminated; `out` is writable.
#[no_mangle]
pub unsafe extern "C" fn iris_adblock_check(e: *const IrisAdblock, url: *const c_char, source_url: *const c_char, request_type: *const c_char, out: *mut IrisVerdict) -> bool {
    if out.is_null() {
        return false;
    }
    *out = IrisVerdict { action: IRIS_ALLOW, payload: std::ptr::null_mut() };
    let (Some(e), Some(url), Some(src), Some(rt)) = (e.as_ref(), from_c(url), from_c(source_url), from_c(request_type)) else { return false };
    let Ok(req) = Request::new(url, src, rt) else { return false };
    let r = e.engine.check_network_request(&req);
    if r.matched && r.exception.is_none() || r.important {
        *out = match r.redirect {
            Some(body) => IrisVerdict { action: IRIS_REDIRECT, payload: to_c(body) },
            None => IrisVerdict { action: IRIS_BLOCK, payload: std::ptr::null_mut() },
        };
    } else if let Some(u) = r.rewritten_url {
        *out = IrisVerdict { action: IRIS_REWRITE, payload: to_c(u) };
    }
    true
}

/// frees a verdict's payload
///
/// # Safety
/// `v` is null or a verdict `iris_adblock_check` filled, freed once.
#[no_mangle]
pub unsafe extern "C" fn iris_verdict_free(v: *mut IrisVerdict) {
    if let Some(v) = v.as_mut() {
        crate::iris_string_free(v.payload);
        v.payload = std::ptr::null_mut();
    }
}

/// what a page at `url` needs, as JSON: {"css": "...", "script": "...",
/// "generichide": bool, "exceptions": ["..."]}. css hides the selectors
/// (display:none !important) and applies the style rules; script is the
/// scriptlets to run before the page's own. null for a bad argument.
///
/// # Safety
/// `e` is live; `url` is NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn iris_adblock_cosmetic(e: *const IrisAdblock, url: *const c_char) -> *mut c_char {
    let (Some(e), Some(url)) = (e.as_ref(), from_c(url)) else { return std::ptr::null_mut() };
    let r = e.engine.url_cosmetic_resources(url);
    let mut css = String::new();
    let mut sels: Vec<&String> = r.hide_selectors.iter().collect();
    sels.sort();
    // many selectors per rule keeps the sheet small; a bad one must not
    // spoil the rest, so each rule has its own few
    for chunk in sels.chunks(32) {
        let joined: Vec<&str> = chunk.iter().map(|s| s.as_str()).collect();
        css.push_str(&joined.join(","));
        css.push_str("{display:none!important}\n");
    }
    let mut exc: Vec<&String> = r.exceptions.iter().collect();
    exc.sort();
    let json = serde_json::json!({
        "css": css,
        "script": r.injected_script,
        "generichide": r.generichide,
        "exceptions": exc,
    });
    to_c(json.to_string())
}

/// the generic hiding rules for the classes and ids a page uses (one per
/// line in each argument), as CSS; null for a bad argument
///
/// # Safety
/// `e` is live; the strings are NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn iris_adblock_class_id_css(e: *const IrisAdblock, classes: *const c_char, ids: *const c_char, exceptions: *const c_char) -> *mut c_char {
    let (Some(e), Some(c), Some(i), Some(x)) = (e.as_ref(), from_c(classes), from_c(ids), from_c(exceptions)) else { return std::ptr::null_mut() };
    let classes: Vec<String> = c.lines().filter(|s| !s.is_empty()).map(String::from).collect();
    let ids: Vec<String> = i.lines().filter(|s| !s.is_empty()).map(String::from).collect();
    let exc: HashSet<String> = x.lines().filter(|s| !s.is_empty()).map(String::from).collect();
    let sels = e.engine.hidden_class_id_selectors(classes, ids, &exc);
    let mut css = String::new();
    for chunk in sels.chunks(32) {
        css.push_str(&chunk.join(","));
        css.push_str("{display:none!important}\n");
    }
    to_c(css)
}

/// the engine as bytes for a cache file (`iris_bytes_free`); null on failure
///
/// # Safety
/// `e` is live; `len` is writable.
#[no_mangle]
pub unsafe extern "C" fn iris_adblock_serialize(e: *const IrisAdblock, len: *mut usize) -> *mut u8 {
    let Some(e) = e.as_ref() else { return std::ptr::null_mut() };
    match e.engine.serialize() {
        Ok(v) => to_buf(v, len),
        Err(_) => std::ptr::null_mut(),
    }
}

/// an engine from `iris_adblock_serialize`'s bytes; null if they are not
/// this version's (read the lists again then)
///
/// # Safety
/// `p` points at `len` readable bytes.
#[no_mangle]
pub unsafe extern "C" fn iris_adblock_deserialize(p: *const u8, len: usize) -> *mut IrisAdblock {
    let Some(bytes) = from_raw(p, len) else { return std::ptr::null_mut() };
    let mut engine = Engine::default();
    match engine.deserialize(bytes) {
        Ok(()) => Box::into_raw(Box::new(IrisAdblock { engine })),
        Err(_) => std::ptr::null_mut(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{iris_bytes_free, iris_string_free};
    use std::ffi::{CStr, CString};

    fn engine(list: &str) -> *mut IrisAdblock {
        unsafe {
            let b = iris_adblock_builder_create();
            assert!(iris_adblock_builder_add_list(b, list.as_ptr(), list.len()));
            let e = iris_adblock_build(b);
            iris_adblock_builder_destroy(b);
            e
        }
    }

    fn check(e: *const IrisAdblock, url: &str, src: &str, ty: &str) -> (u32, Option<String>) {
        let (u, s, t) = (CString::new(url).unwrap(), CString::new(src).unwrap(), CString::new(ty).unwrap());
        let mut v = IrisVerdict { action: 9, payload: std::ptr::null_mut() };
        unsafe {
            assert!(iris_adblock_check(e, u.as_ptr(), s.as_ptr(), t.as_ptr(), &mut v));
            let p = if v.payload.is_null() { None } else { Some(CStr::from_ptr(v.payload).to_string_lossy().into_owned()) };
            iris_verdict_free(&mut v);
            (v.action, p)
        }
    }

    #[test]
    fn blocks_allows_and_excepts() {
        let e = engine("||ads.example.com^\n@@||ads.example.com/ok.js^\n||tracker.net^$third-party\n");
        assert!(!e.is_null());
        assert_eq!(check(e, "https://ads.example.com/a.js", "https://site.org/", "script").0, IRIS_BLOCK);
        assert_eq!(check(e, "https://ads.example.com/ok.js", "https://site.org/", "script").0, IRIS_ALLOW);
        assert_eq!(check(e, "https://tracker.net/x", "https://site.org/", "image").0, IRIS_BLOCK);
        assert_eq!(check(e, "https://tracker.net/x", "https://tracker.net/", "image").0, IRIS_ALLOW);
        assert_eq!(check(e, "https://good.org/a.js", "https://site.org/", "script").0, IRIS_ALLOW);
        unsafe { iris_adblock_destroy(e) };
    }

    #[test]
    fn removeparam_rewrites() {
        let e = engine("||shop.example^$removeparam=trk\n");
        let (a, p) = check(e, "https://shop.example/p?id=1&trk=abc", "https://shop.example/", "document");
        assert_eq!(a, IRIS_REWRITE);
        assert_eq!(p.as_deref(), Some("https://shop.example/p?id=1"));
        unsafe { iris_adblock_destroy(e) };
    }

    #[test]
    fn cosmetic_css() {
        let e = engine("##.generic-ad\nexample.org##.promo\nexample.org##+js(set-constant, adsOn, false)\n");
        let c = CString::new("https://example.org/page").unwrap();
        unsafe {
            let j = iris_adblock_cosmetic(e, c.as_ptr());
            let v: serde_json::Value = serde_json::from_str(CStr::from_ptr(j).to_str().unwrap()).unwrap();
            iris_string_free(j);
            assert!(v["css"].as_str().unwrap().contains(".promo"));
            iris_adblock_destroy(e);
        }
    }

    #[test]
    fn cache_roundtrip_and_bad_input() {
        let e = engine("||ads.example.com^\n");
        unsafe {
            let mut n = 0usize;
            let p = iris_adblock_serialize(e, &mut n);
            assert!(!p.is_null() && n > 0);
            let e2 = iris_adblock_deserialize(p, n);
            assert!(!e2.is_null());
            assert_eq!(check(e2, "https://ads.example.com/x", "https://s.org/", "script").0, IRIS_BLOCK);
            let junk = [1u8, 2, 3];
            assert!(iris_adblock_deserialize(junk.as_ptr(), junk.len()).is_null());
            assert!(iris_adblock_deserialize(std::ptr::null(), 5).is_null());
            iris_bytes_free(p, n);
            iris_adblock_destroy(e);
            iris_adblock_destroy(e2);
            // nulls never crash
            let mut v = IrisVerdict { action: 0, payload: std::ptr::null_mut() };
            assert!(!iris_adblock_check(std::ptr::null(), std::ptr::null(), std::ptr::null(), std::ptr::null(), &mut v));
            assert!(iris_adblock_build(std::ptr::null_mut()).is_null());
            assert!(iris_adblock_cosmetic(std::ptr::null(), std::ptr::null()).is_null());
        }
    }

    #[test]
    fn empty_builder_gives_no_engine() {
        unsafe {
            let b = iris_adblock_builder_create();
            assert!(iris_adblock_build(b).is_null());
            iris_adblock_builder_destroy(b);
        }
    }
}
