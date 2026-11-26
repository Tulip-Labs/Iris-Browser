//! Which address is a Mozilla add-on page, or a Chrome Web Store page.

use crate::{from_c, to_c};
use std::ffi::c_char;

const AMO: &str = "addons.mozilla.org";

/// (scheme-less) host and path of an https address; None for anything else
fn split(url: &str) -> Option<(&str, &str)> {
    let rest = url.strip_prefix("https://")?;
    let end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let host = &rest[..end];
    if host.is_empty() || host.contains('@') || host.contains(':') {
        return None;
    }
    let after = &rest[end..];
    let path_end = after.find(['?', '#']).unwrap_or(after.len());
    Some((host, &after[..path_end]))
}

fn slug_ok(s: &str) -> bool {
    !s.is_empty() && s.len() <= 100 && !s.starts_with('.') && !s.contains("..") && s.bytes().all(|c| c.is_ascii_alphanumeric() || matches!(c, b'-' | b'_' | b'.' | b'~'))
}

fn percent_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            if let Some(v) = std::str::from_utf8(&b[i + 1..i + 3]).ok().and_then(|h| u8::from_str_radix(h, 16).ok()) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn percent_encode(s: &str) -> String {
    let mut out = String::new();
    for c in s.bytes() {
        if c.is_ascii_alphanumeric() || matches!(c, b'-' | b'_' | b'.' | b'~') {
            out.push(c as char);
        } else {
            out.push_str(&format!("%{c:02X}"));
        }
    }
    out
}

/// {"kind":"amo","slug":..,"api":..} for an add-on page of addons.mozilla.org,
/// {"kind":"cws","name":..,"search":..} for a Chrome Web Store extension
/// page, {"kind":""} for anything else
pub fn classify(url: &str) -> serde_json::Value {
    let none = serde_json::json!({"kind": ""});
    let Some((host, path)) = split(url) else { return none };
    let host = host.to_ascii_lowercase();
    let seg: Vec<&str> = path.split('/').filter(|s| !s.is_empty()).collect();
    if host == AMO {
        // /<locale>/firefox/addon/<slug>/ , /<locale>/android/addon/<slug>/ , /firefox/addon/<slug>/
        for i in 0..seg.len().saturating_sub(1) {
            if seg[i] == "addon" && i >= 1 && (seg[i - 1] == "firefox" || seg[i - 1] == "android") && slug_ok(seg[i + 1]) {
                let slug = seg[i + 1];
                return serde_json::json!({
                    "kind": "amo",
                    "slug": slug,
                    "api": format!("https://{AMO}/api/v5/addons/addon/{slug}/"),
                });
            }
        }
        return none;
    }
    let cws = (host == "chromewebstore.google.com" && seg.first() == Some(&"detail"))
        || (host == "chrome.google.com" && seg.first() == Some(&"webstore") && seg.get(1) == Some(&"detail"));
    if cws {
        let k = if host == "chrome.google.com" { 2 } else { 1 };
        // /detail/<name>/<32-letter id> ; the name part may be missing
        let (name_part, has_id) = match (seg.get(k), seg.get(k + 1)) {
            (Some(n), Some(_)) => (Some(*n), true),
            (Some(n), None) if n.len() == 32 && n.bytes().all(|c| c.is_ascii_lowercase()) => (None, true),
            (Some(n), None) => (Some(*n), false),
            _ => (None, false),
        };
        let _ = has_id;
        let name = name_part.map(|n| percent_decode(n).replace(['-', '_', '+'], " ")).map(|n| n.trim().to_string()).filter(|n| !n.is_empty() && n.chars().count() <= 80);
        let search = match &name {
            Some(n) => format!("https://{AMO}/en-US/firefox/search/?q={}&type=extension", percent_encode(n)),
            None => format!("https://{AMO}/en-US/firefox/extensions/"),
        };
        return serde_json::json!({"kind": "cws", "name": name.unwrap_or_default(), "search": search});
    }
    none
}

/// the classification of an address, as JSON (`iris_string_free` it)
///
/// # Safety
/// `url` is null or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn iris_url_classify(url: *const c_char) -> *mut c_char {
    let Some(u) = from_c(url) else { return std::ptr::null_mut() };
    to_c(classify(u).to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn amo() {
        let v = classify("https://addons.mozilla.org/en-US/firefox/addon/ublock-origin/?utm_source=x");
        assert_eq!(v["kind"], "amo");
        assert_eq!(v["slug"], "ublock-origin");
        assert_eq!(v["api"], "https://addons.mozilla.org/api/v5/addons/addon/ublock-origin/");
        assert_eq!(classify("https://addons.mozilla.org/firefox/addon/foo_bar/")["slug"], "foo_bar");
        assert_eq!(classify("https://addons.mozilla.org/en-US/firefox/")["kind"], "");
        // another host, a look-alike, http, and a port
        assert_eq!(classify("https://addons.mozilla.org.evil.com/en-US/firefox/addon/x/")["kind"], "");
        assert_eq!(classify("http://addons.mozilla.org/en-US/firefox/addon/x/")["kind"], "");
        assert_eq!(classify("https://addons.mozilla.org:8443/en-US/firefox/addon/x/")["kind"], "");
        assert_eq!(classify("https://addons.mozilla.org/en-US/firefox/addon/../../x/")["kind"], "");
    }

    #[test]
    fn cws() {
        let v = classify("https://chromewebstore.google.com/detail/ublock-origin/cjpalhdlnbpafiamejdnhcphjbkeiagm?hl=en");
        assert_eq!(v["kind"], "cws");
        assert_eq!(v["name"], "ublock origin");
        assert_eq!(v["search"], "https://addons.mozilla.org/en-US/firefox/search/?q=ublock%20origin&type=extension");
        let v = classify("https://chrome.google.com/webstore/detail/dark-reader/eimadpbcbfnmbkopoojfekhnkhdbieeh");
        assert_eq!(v["name"], "dark reader");
        let v = classify("https://chromewebstore.google.com/detail/cjpalhdlnbpafiamejdnhcphjbkeiagm");
        assert_eq!(v["kind"], "cws");
        assert_eq!(v["name"], "");
        assert_eq!(classify("https://chromewebstore.google.com/category/extensions")["kind"], "");
        assert_eq!(classify("https://chromewebstore.google.com.evil.com/detail/x/y")["kind"], "");
        assert_eq!(classify("javascript:alert(1)")["kind"], "");
    }

    #[test]
    fn decode() {
        assert_eq!(percent_decode("a%20b%zz%"), "a b%zz%");
        assert_eq!(percent_decode("%C3%A9"), "é");
    }
}
