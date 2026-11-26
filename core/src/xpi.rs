//! Mozilla add-ons: an `.xpi` is a ZIP archive with a `manifest.json`.
//!
//! `install` checks the download against the SHA-256 Mozilla's API gave,
//! refuses any entry that would land outside the extension's folder
//! (Zip-Slip: "..", absolute paths, symlinks), caps the size of what it
//! unpacks (ZIP bombs), unpacks into a temporary folder and moves it into
//! place whole, then returns what `manifest.json` says (Manifest V2 or V3)
//! in the shape the browser needs.

use crate::{from_c, from_raw, to_c};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::ffi::c_char;
use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

const MAX_ENTRIES: usize = 20_000;
const MAX_TOTAL: u64 = 512 * 1024 * 1024;
const MAX_FILE: u64 = 128 * 1024 * 1024;
const MAX_MANIFEST: u64 = 2 * 1024 * 1024;

#[derive(Debug, PartialEq, Eq)]
pub enum XpiError {
    BadHash,
    NotZip,
    TooBig,
    Unsafe(String),
    NoManifest,
    BadManifest,
    Io,
}

impl XpiError {
    /// the code the C side gets
    pub fn code(&self) -> i32 {
        match self {
            XpiError::BadHash => -1,
            XpiError::NotZip => -2,
            XpiError::TooBig => -3,
            XpiError::Unsafe(_) => -4,
            XpiError::NoManifest => -5,
            XpiError::BadManifest => -6,
            XpiError::Io => -7,
        }
    }
}

/// a folder name for an add-on id: letters, digits and . _ - @ only
pub fn dir_name(id: &str) -> String {
    let s: String = id.chars().map(|c| if c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-' | '@') { c } else { '_' }).take(100).collect();
    // never "", ".", ".." or hidden
    if s.is_empty() || s.starts_with('.') { format!("x{s}") } else { s }
}

fn fnv(data: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in data {
        h ^= *b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    h
}

/// the manifest as JSON; Firefox allows whole-line // comments in it
fn parse_json(raw: &[u8]) -> Option<Value> {
    let text = std::str::from_utf8(raw).ok()?.trim_start_matches('\u{feff}');
    if let Ok(v) = serde_json::from_str::<Value>(text) {
        return Some(v);
    }
    let stripped: String = text.lines().filter(|l| !l.trim_start().starts_with("//")).collect::<Vec<_>>().join("\n");
    serde_json::from_str(&stripped).ok()
}

fn strings(v: &Value) -> Vec<String> {
    v.as_array().map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect()).unwrap_or_default()
}

/// a host pattern ("https://*/*", "*://*.example.com/*", "<all_urls>")
fn is_host_pattern(p: &str) -> bool {
    p == "<all_urls>" || p.contains("://")
}

/// the icon to use out of "default_icon" / "icons": a path, or the largest of a map
fn pick_icon(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        Value::Object(m) => m.iter().filter_map(|(k, v)| Some((k.parse::<u32>().ok()?, v.as_str()?))).max_by_key(|(k, _)| *k).map(|(_, v)| v.to_string()).unwrap_or_default(),
        _ => String::new(),
    }
}

/// `__MSG_name__` from `_locales/<default_locale>/messages.json`
fn localized(s: &str, locale: &Value) -> String {
    if let Some(key) = s.strip_prefix("__MSG_").and_then(|k| k.strip_suffix("__")) {
        if let Some(m) = locale.get(key).or_else(|| locale.get(key.to_ascii_lowercase())).and_then(|e| e.get("message")).and_then(|m| m.as_str()) {
            return m.to_string();
        }
    }
    s.to_string()
}

/// what the browser needs from a manifest (V2 and V3)
pub fn summarize(m: &Value, locale: &Value, fallback_id: &str) -> Result<Value, XpiError> {
    let mv = m.get("manifest_version").and_then(Value::as_u64).ok_or(XpiError::BadManifest)?;
    if mv != 2 && mv != 3 {
        return Err(XpiError::BadManifest);
    }
    let name = m.get("name").and_then(Value::as_str).ok_or(XpiError::BadManifest)?;
    let version = m.get("version").and_then(Value::as_str).ok_or(XpiError::BadManifest)?;
    let gecko = m.pointer("/browser_specific_settings/gecko/id").or_else(|| m.pointer("/applications/gecko/id")).and_then(Value::as_str);
    let id = gecko.map(String::from).unwrap_or_else(|| fallback_id.to_string());

    let mut api_perms = Vec::new();
    let mut hosts = Vec::new();
    for p in strings(&m["permissions"]).into_iter().chain(strings(&m["host_permissions"])) {
        if is_host_pattern(&p) { hosts.push(p) } else { api_perms.push(p) }
    }
    let optional: Vec<String> = strings(&m["optional_permissions"]).into_iter().chain(strings(&m["optional_host_permissions"])).collect();

    let bg = &m["background"];
    let background = json!({
        "scripts": strings(&bg["scripts"]),
        "service_worker": bg["service_worker"].as_str().unwrap_or(""),
        "page": bg["page"].as_str().unwrap_or(""),
        "persistent": bg["persistent"].as_bool().unwrap_or(mv == 2),
        "type": bg["type"].as_str().unwrap_or("classic"),
    });

    let mut content_scripts = Vec::new();
    if let Some(a) = m["content_scripts"].as_array() {
        for c in a {
            let run_at = match c["run_at"].as_str() {
                Some("document_start") => "document_start",
                Some("document_end") => "document_end",
                _ => "document_idle",
            };
            content_scripts.push(json!({
                "matches": strings(&c["matches"]),
                "exclude_matches": strings(&c["exclude_matches"]),
                "js": strings(&c["js"]),
                "css": strings(&c["css"]),
                "run_at": run_at,
                "all_frames": c["all_frames"].as_bool().unwrap_or(false),
                "match_about_blank": c["match_about_blank"].as_bool().unwrap_or(false),
                "world": c["world"].as_str().unwrap_or("ISOLATED"),
            }));
        }
    }

    let action = if mv == 3 { &m["action"] } else { &m["browser_action"] };
    let action = if action.is_null() { &m["browser_action"] } else { action };
    let war = &m["web_accessible_resources"];
    // V2: ["a.png"], V3: [{"resources": [...], "matches": [...]}]
    let mut web_accessible: Vec<String> = strings(war);
    if let Some(a) = war.as_array() {
        for e in a {
            web_accessible.extend(strings(&e["resources"]));
        }
    }

    Ok(json!({
        "id": id,
        "dir": dir_name(&id),
        "name": localized(name, locale),
        "description": localized(m["description"].as_str().unwrap_or(""), locale),
        "version": version,
        "manifest_version": mv,
        "has_gecko_id": gecko.is_some(),
        "permissions": api_perms,
        "host_permissions": hosts,
        "optional_permissions": optional,
        "background": background,
        "content_scripts": content_scripts,
        "action": {
            "popup": action["default_popup"].as_str().unwrap_or(""),
            "title": localized(action["default_title"].as_str().unwrap_or(""), locale),
            "icon": pick_icon(&action["default_icon"]),
        },
        "icon": pick_icon(&m["icons"]),
        "options_page": m.pointer("/options_ui/page").or_else(|| m.get("options_page")).and_then(Value::as_str).unwrap_or(""),
        "web_accessible_resources": web_accessible,
        "default_locale": m["default_locale"].as_str().unwrap_or(""),
    }))
}

fn read_limited<R: Read>(r: R, limit: u64) -> Result<Vec<u8>, XpiError> {
    let mut v = Vec::new();
    r.take(limit + 1).read_to_end(&mut v).map_err(|_| XpiError::Io)?;
    if v.len() as u64 > limit { Err(XpiError::TooBig) } else { Ok(v) }
}

/// the manifest of an `.xpi`, without unpacking anything
pub fn read_manifest(bytes: &[u8]) -> Result<Value, XpiError> {
    let mut z = zip::ZipArchive::new(std::io::Cursor::new(bytes)).map_err(|_| XpiError::NotZip)?;
    let fallback = format!("addon-{:016x}@iris.local", fnv(bytes));
    let raw = read_limited(z.by_name("manifest.json").map_err(|_| XpiError::NoManifest)?, MAX_MANIFEST)?;
    let m = parse_json(&raw).ok_or(XpiError::BadManifest)?;
    let locale = match m.get("default_locale").and_then(Value::as_str) {
        Some(l) if l.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'_' || c == b'-') => z
            .by_name(&format!("_locales/{l}/messages.json"))
            .ok()
            .and_then(|f| read_limited(f, MAX_MANIFEST).ok())
            .and_then(|r| parse_json(&r))
            .unwrap_or(Value::Null),
        _ => Value::Null,
    };
    summarize(&m, &locale, &fallback)
}

fn hex(d: &[u8]) -> String {
    d.iter().map(|b| format!("{b:02x}")).collect()
}

/// installs an `.xpi` under `dest/<dir name of its id>/`; returns the summary.
/// `sha256` is the checksum Mozilla's API gave (hex, "sha256:" prefix allowed).
pub fn install(bytes: &[u8], dest: &Path, sha256: Option<&str>) -> Result<Value, XpiError> {
    if let Some(want) = sha256 {
        let want = want.trim().trim_start_matches("sha256:").to_ascii_lowercase();
        if hex(&Sha256::digest(bytes)) != want {
            return Err(XpiError::BadHash);
        }
    }
    let mut summary = read_manifest(bytes)?;
    let mut z = zip::ZipArchive::new(std::io::Cursor::new(bytes)).map_err(|_| XpiError::NotZip)?;
    if z.len() > MAX_ENTRIES {
        return Err(XpiError::TooBig);
    }
    // first, every entry's name and size: nothing is written until all are safe
    let mut total: u64 = 0;
    for i in 0..z.len() {
        let f = z.by_index(i).map_err(|_| XpiError::NotZip)?;
        if f.enclosed_name().is_none() || f.name().contains('\\') || f.name().contains('\0') {
            return Err(XpiError::Unsafe(f.name().to_string()));
        }
        if let Some(mode) = f.unix_mode() {
            if mode & 0o170000 == 0o120000 {
                return Err(XpiError::Unsafe(format!("{} is a symbolic link", f.name())));
            }
        }
        if f.size() > MAX_FILE {
            return Err(XpiError::TooBig);
        }
        total = total.saturating_add(f.size());
        if total > MAX_TOTAL {
            return Err(XpiError::TooBig);
        }
    }
    let dir = summary["dir"].as_str().ok_or(XpiError::BadManifest)?.to_string();
    fs::create_dir_all(dest).map_err(|_| XpiError::Io)?;
    let tmp = dest.join(format!(".installing-{}-{}", dir, std::process::id()));
    let _ = fs::remove_dir_all(&tmp);
    fs::create_dir(&tmp).map_err(|_| XpiError::Io)?;
    let result = (|| -> Result<(), XpiError> {
        let mut written: u64 = 0;
        for i in 0..z.len() {
            let f = z.by_index(i).map_err(|_| XpiError::NotZip)?;
            let rel = f.enclosed_name().ok_or_else(|| XpiError::Unsafe(f.name().to_string()))?;
            let out: PathBuf = tmp.join(&rel);
            // belt and braces: still inside tmp
            if !out.starts_with(&tmp) {
                return Err(XpiError::Unsafe(f.name().to_string()));
            }
            if f.is_dir() {
                fs::create_dir_all(&out).map_err(|_| XpiError::Io)?;
                continue;
            }
            if let Some(p) = out.parent() {
                fs::create_dir_all(p).map_err(|_| XpiError::Io)?;
            }
            // the real size counts, not the declared one
            let data = read_limited(f, MAX_FILE)?;
            written += data.len() as u64;
            if written > MAX_TOTAL {
                return Err(XpiError::TooBig);
            }
            let mut file = fs::OpenOptions::new().write(true).create_new(true).open(&out).map_err(|_| XpiError::Io)?;
            file.write_all(&data).map_err(|_| XpiError::Io)?;
        }
        Ok(())
    })();
    if let Err(e) = result {
        let _ = fs::remove_dir_all(&tmp);
        return Err(e);
    }
    let fin = dest.join(&dir);
    let _ = fs::remove_dir_all(&fin);
    if fs::rename(&tmp, &fin).is_err() {
        let _ = fs::remove_dir_all(&tmp);
        return Err(XpiError::Io);
    }
    summary["path"] = Value::String(fin.to_string_lossy().into_owned());
    Ok(summary)
}

/// removes an installed add-on's folder (`dir` is the summary's "dir")
pub fn uninstall(dest: &Path, dir: &str) -> bool {
    if dir != dir_name(dir) {
        return false;
    }
    fs::remove_dir_all(dest.join(dir)).is_ok()
}

/// What the summary of an `.xpi`'s manifest is, without unpacking it: JSON
/// (`iris_string_free` it), or null if it is not an add-on.
///
/// # Safety
/// `xpi` points at `len` readable bytes.
#[no_mangle]
pub unsafe extern "C" fn iris_xpi_inspect(xpi: *const u8, len: usize) -> *mut c_char {
    let Some(b) = from_raw(xpi, len) else { return std::ptr::null_mut() };
    match read_manifest(b) {
        Ok(v) => to_c(v.to_string()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Installs an `.xpi` under `dest_dir`. `sha256` is Mozilla's checksum (may
/// be null: then none is checked). On success returns 0 and the summary
/// JSON in `*out` (`iris_string_free` it; `out` may be null); on failure a
/// negative code: -1 checksum, -2 not a ZIP, -3 too big, -4 unsafe path or
/// link, -5 no manifest.json, -6 bad manifest, -7 disk.
///
/// # Safety
/// `xpi` points at `len` readable bytes; the strings are NUL-terminated or
/// null; `out` is null or writable.
#[no_mangle]
pub unsafe extern "C" fn iris_xpi_install(xpi: *const u8, len: usize, dest_dir: *const c_char, sha256: *const c_char, out: *mut *mut c_char) -> i32 {
    if !out.is_null() {
        *out = std::ptr::null_mut();
    }
    let (Some(b), Some(dest)) = (from_raw(xpi, len), from_c(dest_dir)) else { return XpiError::Io.code() };
    if dest.is_empty() {
        return XpiError::Io.code();
    }
    match install(b, Path::new(dest), from_c(sha256)) {
        Ok(v) => {
            if !out.is_null() {
                *out = to_c(v.to_string());
            }
            0
        }
        Err(e) => e.code(),
    }
}

/// removes an installed add-on; false if `dir` is not a plain folder name
/// or there was nothing to remove
///
/// # Safety
/// The strings are NUL-terminated or null.
#[no_mangle]
pub unsafe extern "C" fn iris_xpi_uninstall(dest_dir: *const c_char, dir: *const c_char) -> bool {
    match (from_c(dest_dir), from_c(dir)) {
        (Some(d), Some(n)) if !d.is_empty() && !n.is_empty() => uninstall(Path::new(d), n),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;
    use zip::write::SimpleFileOptions;

    fn make(files: &[(&str, &[u8])]) -> Vec<u8> {
        let mut w = zip::ZipWriter::new(Cursor::new(Vec::new()));
        for (n, d) in files {
            w.start_file(*n, SimpleFileOptions::default()).unwrap();
            w.write_all(d).unwrap();
        }
        w.finish().unwrap().into_inner()
    }

    const MV3: &str = r#"{"manifest_version":3,"name":"__MSG_n__","version":"1.2.3","default_locale":"en",
      "browser_specific_settings":{"gecko":{"id":"x@example.org"}},
      "permissions":["storage","tabs","https://a.example/*"],"host_permissions":["<all_urls>"],
      "background":{"scripts":["bg.js"]},
      "content_scripts":[{"matches":["https://*/*"],"js":["c.js"],"run_at":"document_start"}],
      "action":{"default_popup":"p.html","default_icon":{"16":"i16.png","48":"i48.png"}},
      "web_accessible_resources":[{"resources":["a.png"],"matches":["<all_urls>"]}]}"#;

    fn tmpdir(n: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("iris-core-{n}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        d
    }

    #[test]
    fn manifest_v3_and_v2() {
        let x = make(&[("manifest.json", MV3.as_bytes()), ("_locales/en/messages.json", br#"{"n":{"message":"My Add-on"}}"#), ("bg.js", b"1")]);
        let v = read_manifest(&x).unwrap();
        assert_eq!(v["id"], "x@example.org");
        assert_eq!(v["name"], "My Add-on");
        assert_eq!(v["manifest_version"], 3);
        assert_eq!(v["permissions"], json!(["storage", "tabs"]));
        assert_eq!(v["host_permissions"], json!(["https://a.example/*", "<all_urls>"]));
        assert_eq!(v["background"]["scripts"], json!(["bg.js"]));
        assert_eq!(v["content_scripts"][0]["run_at"], "document_start");
        assert_eq!(v["action"]["popup"], "p.html");
        assert_eq!(v["action"]["icon"], "i48.png");
        assert_eq!(v["web_accessible_resources"], json!(["a.png"]));
        let v2 = make(&[("manifest.json", br#"// c
{"manifest_version":2,"name":"Old","version":"0.1","applications":{"gecko":{"id":"{abc}"}},"browser_action":{"default_popup":"x.html"},"background":{"scripts":["a.js"],"persistent":false}}"#)]);
        let v = read_manifest(&v2).unwrap();
        assert_eq!(v["id"], "{abc}");
        assert_eq!(v["dir"], "_abc_");
        assert_eq!(v["action"]["popup"], "x.html");
        assert_eq!(v["background"]["persistent"], false);
    }

    #[test]
    fn no_id_gets_a_local_one() {
        let x = make(&[("manifest.json", br#"{"manifest_version":3,"name":"n","version":"1"}"#)]);
        assert!(read_manifest(&x).unwrap()["id"].as_str().unwrap().ends_with("@iris.local"));
    }

    #[test]
    fn bad_archives() {
        assert_eq!(read_manifest(b"not a zip").unwrap_err(), XpiError::NotZip);
        assert_eq!(read_manifest(&make(&[("a.txt", b"x")])).unwrap_err(), XpiError::NoManifest);
        assert_eq!(read_manifest(&make(&[("manifest.json", b"{")])).unwrap_err(), XpiError::BadManifest);
        assert_eq!(read_manifest(&make(&[("manifest.json", br#"{"manifest_version":9,"name":"a","version":"1"}"#)])).unwrap_err(), XpiError::BadManifest);
    }

    #[test]
    fn installs_and_replaces() {
        let d = tmpdir("ok");
        let x = make(&[("manifest.json", MV3.as_bytes()), ("sub/bg.js", b"hello")]);
        let want = hex(&Sha256::digest(&x));
        let v = install(&x, &d, Some(&format!("sha256:{want}"))).unwrap();
        assert_eq!(fs::read(d.join("x@example.org/sub/bg.js")).unwrap(), b"hello");
        assert_eq!(v["path"], d.join("x@example.org").to_string_lossy().as_ref());
        // again: replaced, no leftovers
        install(&x, &d, None).unwrap();
        let names: Vec<_> = fs::read_dir(&d).unwrap().map(|e| e.unwrap().file_name().into_string().unwrap()).collect();
        assert_eq!(names, vec!["x@example.org"]);
        assert!(uninstall(&d, "x@example.org"));
        assert!(!uninstall(&d, "../x"));
        let _ = fs::remove_dir_all(&d);
    }

    #[test]
    fn wrong_hash_refused() {
        let d = tmpdir("hash");
        let x = make(&[("manifest.json", MV3.as_bytes())]);
        assert_eq!(install(&x, &d, Some(&"0".repeat(64))).unwrap_err(), XpiError::BadHash);
        assert!(!d.exists());
    }

    #[test]
    fn zip_slip_refused_and_nothing_written() {
        let d = tmpdir("slip");
        for evil in ["../evil.txt", "a/../../evil.txt", "/etc/evil", "a\\..\\evil"] {
            let x = make(&[("manifest.json", MV3.as_bytes()), (evil, b"x")]);
            assert!(matches!(install(&x, &d, None), Err(XpiError::Unsafe(_))), "{evil}");
        }
        assert!(!d.join("x@example.org").exists());
        assert!(!d.parent().unwrap().join("evil.txt").exists());
        let _ = fs::remove_dir_all(&d);
    }

    #[test]
    fn symlink_refused() {
        let d = tmpdir("link");
        let mut w = zip::ZipWriter::new(Cursor::new(Vec::new()));
        w.start_file("manifest.json", SimpleFileOptions::default()).unwrap();
        w.write_all(MV3.as_bytes()).unwrap();
        w.add_symlink("link", "/etc/passwd", SimpleFileOptions::default()).unwrap();
        let x = w.finish().unwrap().into_inner();
        assert!(matches!(install(&x, &d, None), Err(XpiError::Unsafe(_))));
        let _ = fs::remove_dir_all(&d);
    }

    #[test]
    fn hostile_ids_stay_inside() {
        assert_eq!(dir_name("../../x"), "x.._.._x");
        assert_eq!(dir_name(".."), "x..");
        assert_eq!(dir_name("a/b"), "a_b");
        assert_eq!(dir_name(""), "x");
        let d = tmpdir("id");
        let m = br#"{"manifest_version":3,"name":"n","version":"1","browser_specific_settings":{"gecko":{"id":"../../escape"}}}"#;
        let x = make(&[("manifest.json", m)]);
        let v = install(&x, &d, None).unwrap();
        assert!(Path::new(v["path"].as_str().unwrap()).starts_with(&d));
        let _ = fs::remove_dir_all(&d);
    }

    #[test]
    fn c_interface() {
        let d = tmpdir("c");
        let x = make(&[("manifest.json", MV3.as_bytes())]);
        let dest = std::ffi::CString::new(d.to_str().unwrap()).unwrap();
        let mut out: *mut c_char = std::ptr::null_mut();
        unsafe {
            assert_eq!(iris_xpi_install(x.as_ptr(), x.len(), dest.as_ptr(), std::ptr::null(), &mut out), 0);
            assert!(!out.is_null());
            crate::iris_string_free(out);
            assert_eq!(iris_xpi_install(std::ptr::null(), 4, dest.as_ptr(), std::ptr::null(), &mut out), -7);
            assert_eq!(iris_xpi_install(b"zz".as_ptr(), 2, dest.as_ptr(), std::ptr::null(), &mut out), -2);
            assert!(iris_xpi_inspect(std::ptr::null(), 3).is_null());
        }
        let _ = fs::remove_dir_all(&d);
    }
}
