#!/usr/bin/env python3
"""Keeps Iris (Chromium) on the newest stable CEF Spotify publishes.

  cef-update.py latest [--index URL|FILE] [--lock FILE]
      prints key=value lines (for $GITHUB_OUTPUT): update, major_bump,
      cef_version, chromium, name, sha1, current
  cef-update.py apply --cef-version V --sha1 H --sha256 H [--root DIR]
      writes the lock, the Flatpak manifest, the docs that name the build, and
      bumps Iris (Chromium)'s own version and release notes

Only the Python standard library. Nothing here touches .github/workflows:
a workflow run with GITHUB_TOKEN may not change those files, so the pin
lives in packaging/cef_version.lock and the workflows read it.
"""
import argparse
import json
import re
import sys
import urllib.request
from pathlib import Path

INDEX_URL = "https://cef-builds.spotifycdn.com/index.json"
CEF_RE = re.compile(r"^(\d+\.\d+\.\d+)\+g([0-9a-f]+)\+chromium-(\d+)\.(\d+)\.(\d+)\.(\d+)$")


def parse_cef_version(v):
    m = CEF_RE.match(v)
    if not m:
        raise ValueError(f"not a CEF version: {v!r}")
    return {"cef": m.group(1), "hash": m.group(2), "chromium": ".".join(m.group(3, 4, 5, 6)), "major": int(m.group(3)), "key": tuple(int(x) for x in m.group(3, 4, 5, 6)) + tuple(int(x) for x in m.group(1).split("."))}


def read_lock(path):
    d = {}
    for line in Path(path).read_text().splitlines():
        if line.strip() and not line.lstrip().startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            d[k.strip()] = v.strip()
    if "cef_version" not in d:
        raise SystemExit(f"{path} has no cef_version")
    parse_cef_version(d["cef_version"])
    d.setdefault("sha1", "")
    d.setdefault("sha256", "")
    return d


def load_index(src):
    if src.startswith("http"):
        with urllib.request.urlopen(src, timeout=60) as r:
            return json.load(r)
    return json.loads(Path(src).read_text())


def tarball_name(cef_version):
    return f"cef_binary_{cef_version}_linux64_minimal"


def newest(index):
    """the newest stable linux64 build that has a minimal tarball, and the
    newest one of each Chromium major"""
    try:
        versions = index["linux64"]["versions"]
    except (KeyError, TypeError):
        raise SystemExit("index.json has no linux64.versions: its format changed")
    best = {}
    for v in versions:
        if v.get("channel") != "stable":
            continue
        try:
            p = parse_cef_version(v["cef_version"])
        except (KeyError, ValueError):
            continue
        f = next((f for f in v.get("files", []) if f.get("type") == "minimal"), None)
        if not f or not re.fullmatch(r"[0-9a-f]{40}", f.get("sha1", "")):
            continue
        if f.get("name") != tarball_name(v["cef_version"]) + ".tar.bz2":
            continue
        cur = best.get(p["major"])
        if cur is None or p["key"] > cur[0]["key"]:
            best[p["major"]] = (p, v["cef_version"], f["sha1"])
    return best


def cmd_latest(a):
    lock = read_lock(a.lock)
    cur = parse_cef_version(lock["cef_version"])
    best = newest(load_index(a.index))
    if not best:
        raise SystemExit("no stable linux64 minimal build in the index")
    top = max(best)
    # a patch of the major Iris is on is taken on its own; a newer major
    # is taken too, but its pull request waits for a person
    pick = best[top]
    p, ver, sha1 = pick
    same_major = p["major"] == cur["major"]
    newer = p["key"] > cur["key"]
    fill = ver == lock["cef_version"] and (not lock["sha1"] or not lock["sha256"])
    changed = ver == lock["cef_version"] and lock["sha1"] and lock["sha1"] != sha1
    update = newer or fill or bool(changed)
    out = {
        "update": str(update).lower(),
        "major_bump": str(newer and not same_major).lower(),
        "version_changes": str(newer or bool(changed)).lower(),
        "cef_version": ver,
        "chromium": p["chromium"],
        "name": tarball_name(ver) + ".tar.bz2",
        "sha1": sha1,
        "current": lock["cef_version"],
    }
    for k, v in out.items():
        print(f"{k}={v}")


def sub_once(text, pattern, repl, what, flags=0):
    new, n = re.subn(pattern, repl, text, count=1, flags=flags)
    if n != 1:
        raise SystemExit(f"{what}: pattern not found")
    return new


def bump_patch(v):
    a, b, c = v.split(".")
    return f"{a}.{b}.{int(c) + 1}"


def cmd_apply(a):
    root = Path(a.root)
    lockp = root / "packaging/cef_version.lock"
    old = read_lock(lockp)
    new = parse_cef_version(a.cef_version)
    old_p = parse_cef_version(old["cef_version"])
    if not re.fullmatch(r"[0-9a-f]{40}", a.sha1) or not re.fullmatch(r"[0-9a-f]{64}", a.sha256):
        raise SystemExit("sha1 is 40 hex digits and sha256 is 64")
    # the lock
    text = lockp.read_text()
    text = sub_once(text, r"(?m)^cef_version=.*$", f"cef_version={a.cef_version}", "lock cef_version")
    text = sub_once(text, r"(?m)^sha1=.*$", f"sha1={a.sha1}", "lock sha1")
    text = sub_once(text, r"(?m)^sha256=.*$", f"sha256={a.sha256}", "lock sha256")
    lockp.write_text(text)
    # the Flatpak manifest: the CEF source's url and checksum (not Odin's), and its header comment
    mp = root / "packaging/flatpak/io.github.tulip_labs.Iris.Cef.yml"
    m = mp.read_text()
    m = sub_once(m, r"(url: https://cef-builds\.spotifycdn\.com/)cef_binary_\S+?(\n(?: *#.*\n)*? *sha256: )[0-9a-f]{64}", lambda x: f"{x.group(1)}{tarball_name(a.cef_version)}.tar.bz2{x.group(2)}{a.sha256}", "manifest source")
    m = sub_once(m, r"CEF \d+\.\d+\.\d+ \(Chromium [\d.]+\)", f"CEF {new['cef']} (Chromium {new['chromium']})", "manifest comment")
    mp.write_text(m)
    # docs that name the build (best effort: a missing phrase is not an error)
    for rel in ("packaging/flatpak/README.md", "experiments/cef-smoke/README.md"):
        p = root / rel
        if p.exists():
            t = p.read_text()
            t = t.replace(tarball_name(old["cef_version"]), tarball_name(a.cef_version))
            t = re.sub(r"CEF \*{0,2}" + re.escape(old_p["cef"]), lambda x: x.group(0).replace(old_p["cef"], new["cef"]), t)
            t = t.replace(old_p["chromium"], new["chromium"])
            p.write_text(t)
    # Iris (Chromium)'s own version and notes, when the build itself changed
    if a.cef_version != old["cef_version"]:
        vp = root / "linux/src/version_cef.odin"
        v = vp.read_text()
        cur = re.search(r'^CEF_VERSION :: "(\d+\.\d+\.\d+)"', v, re.M)
        if not cur:
            raise SystemExit("no CEF_VERSION in version_cef.odin")
        nv = bump_patch(cur.group(1))
        vp.write_text(v.replace(f'CEF_VERSION :: "{cur.group(1)}"', f'CEF_VERSION :: "{nv}"', 1))
        np_ = root / "packaging/release-notes-cef.md"
        major = "" if new["major"] == old_p["major"] else f" (a new Chromium major, {new['major']})"
        entry = (
            f"Iris (Chromium) {nv}: Chromium {new['chromium']}{major}.\n\n"
            f"- Chromium updated from {old_p['chromium']} to {new['chromium']} (CEF {new['cef']}), with the fixes Chromium shipped in it: see the Chrome Releases blog (chromereleases.googleblog.com). Checked and published automatically.\n\n"
            "**Install**\n- `flatpak install --user --reinstall Iris-Cef-x86_64.flatpak`\n\n---\n\n"
        )
        np_.write_text(entry + np_.read_text())
        print(f"version={nv}")


def main():
    ap = argparse.ArgumentParser()
    sp = ap.add_subparsers(dest="cmd", required=True)
    l = sp.add_parser("latest")
    l.add_argument("--index", default=INDEX_URL)
    l.add_argument("--lock", default="packaging/cef_version.lock")
    l.set_defaults(f=cmd_latest)
    p = sp.add_parser("apply")
    p.add_argument("--cef-version", required=True)
    p.add_argument("--sha1", required=True)
    p.add_argument("--sha256", required=True)
    p.add_argument("--root", default=".")
    p.set_defaults(f=cmd_apply)
    a = ap.parse_args()
    a.f(a)


if __name__ == "__main__":
    main()
