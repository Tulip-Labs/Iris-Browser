//! Iris's Rust core, behind a flat C interface (include/iris_core.h).
//!
//! - `adblock`: Brave's adblock-rust (network rules, redirects, removeparam,
//!   cosmetic filters, scriptlets).
//! - `xpi`: Mozilla add-ons: download-side checks, Zip-Slip safe extraction,
//!   `manifest.json` (Manifest V2 and V3) parsing.
//! - `urls`: which address is an add-on page of Mozilla's or of the Chrome
//!   Web Store.
//!
//! Only flat C types cross the boundary: `*const c_char`, `u8`, `u32`,
//! `bool` and opaque pointers. Every opaque pointer has a `_create` (or a
//! function that makes it) and a `_destroy`. Every pointer is checked for
//! null before it is read. Strings and byte buffers handed to the caller are
//! freed with `iris_string_free` / `iris_bytes_free`.

pub mod adblock_ffi;
pub mod urls;
pub mod xpi;

use std::ffi::{c_char, CStr, CString};

/// the version of this library
#[no_mangle]
pub extern "C" fn iris_core_version() -> *const c_char {
    static V: &CStr = c"0.1.0";
    V.as_ptr()
}

/// frees a string this library returned (null is fine)
///
/// # Safety
/// `s` is null or came from this library and is freed once.
#[no_mangle]
pub unsafe extern "C" fn iris_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}

/// frees a byte buffer this library returned with its length (null is fine)
///
/// # Safety
/// `p`/`len` are exactly what the library returned, freed once.
#[no_mangle]
pub unsafe extern "C" fn iris_bytes_free(p: *mut u8, len: usize) {
    if !p.is_null() {
        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(p, len)));
    }
}

/// a C string for the caller (interior NULs are dropped)
pub(crate) fn to_c(s: String) -> *mut c_char {
    let s = if s.as_bytes().contains(&0) { s.replace('\0', "") } else { s };
    CString::new(s).map(CString::into_raw).unwrap_or(std::ptr::null_mut())
}

/// a `&str` from a C string, or None for null or invalid UTF-8
///
/// # Safety
/// `p` is null or a valid NUL-terminated string.
pub(crate) unsafe fn from_c<'a>(p: *const c_char) -> Option<&'a str> {
    if p.is_null() {
        None
    } else {
        CStr::from_ptr(p).to_str().ok()
    }
}

/// a byte slice from a pointer and a length, or None for null (an empty
/// slice for length 0)
///
/// # Safety
/// `p` is null or points at `len` readable bytes.
pub(crate) unsafe fn from_raw<'a>(p: *const u8, len: usize) -> Option<&'a [u8]> {
    if p.is_null() {
        if len == 0 { Some(&[]) } else { None }
    } else {
        Some(std::slice::from_raw_parts(p, len))
    }
}

/// a buffer for the caller
pub(crate) fn to_buf(v: Vec<u8>, len: *mut usize) -> *mut u8 {
    let b = v.into_boxed_slice();
    if !len.is_null() {
        unsafe { *len = b.len() };
    }
    Box::into_raw(b) as *mut u8
}
