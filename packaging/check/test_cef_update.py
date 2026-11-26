import json, shutil, subprocess, sys, tempfile, unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
SCRIPT = HERE / "cef-update.py"
OLD = "156.0.32+g3d1f4ab+chromium-156.0.8078.109"
SHA1 = "a" * 40


def entry(v, channel="stable", sha1=SHA1, kind="minimal"):
    return {"cef_version": v, "channel": channel, "files": [{"type": kind, "name": f"cef_binary_{v}_linux64_{kind}.tar.bz2", "sha1": sha1}, {"type": "client", "name": f"cef_binary_{v}_linux64_client.tar.bz2", "sha1": "b" * 40}]}


def run(*args, cwd=None):
    return subprocess.run([sys.executable, "-I", str(SCRIPT), *args], capture_output=True, text=True, cwd=cwd)


def kv(out):
    return dict(l.split("=", 1) for l in out.strip().splitlines())


class T(unittest.TestCase):
    def setUp(self):
        self.d = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.d)
        for rel in ("packaging/cef_version.lock", "packaging/flatpak/io.github.tulip_labs.Iris.Cef.yml", "packaging/flatpak/README.md", "linux/src/version_cef.odin", "packaging/release-notes-cef.md"):
            (self.d / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(ROOT / rel, self.d / rel)

    def index(self, *versions):
        p = self.d / "index.json"
        p.write_text(json.dumps({"linux64": {"versions": list(versions)}}))
        return str(p)

    def latest(self, *versions):
        r = run("latest", "--index", self.index(*versions), "--lock", str(self.d / "packaging/cef_version.lock"))
        self.assertEqual(r.returncode, 0, r.stderr)
        return kv(r.stdout)

    def test_same_build_with_no_checksums_fills_them(self):
        o = self.latest(entry(OLD))
        self.assertEqual((o["update"], o["version_changes"]), ("true", "false"))

    def test_same_build_measured_is_quiet(self):
        lock = self.d / "packaging/cef_version.lock"
        lock.write_text(lock.read_text().replace("sha1=\n", f"sha1={SHA1}\n").replace("sha256=\n", "sha256=" + "c" * 64 + "\n"))
        self.assertEqual(self.latest(entry(OLD))["update"], "false")
        # the same version rebuilt upstream: another sha1
        o = self.latest(entry(OLD, sha1="d" * 40))
        self.assertEqual((o["update"], o["version_changes"]), ("true", "true"))

    def test_patch_and_major(self):
        patch = "156.0.33+g1111111+chromium-156.0.8078.140"
        major = "157.0.5+g2222222+chromium-157.0.8100.10"
        o = self.latest(entry(OLD), entry(patch))
        self.assertEqual((o["update"], o["major_bump"], o["cef_version"]), ("true", "false", patch))
        o = self.latest(entry(OLD), entry(patch), entry(major))
        self.assertEqual((o["update"], o["major_bump"], o["cef_version"]), ("true", "true", major))

    def test_beta_and_odd_entries_ignored(self):
        beta = "157.0.1+g3333333+chromium-157.0.8101.1"
        o = self.latest(entry(OLD), entry(beta, channel="beta"), entry("158.0.1+g4444444+chromium-158.0.1.1", kind="client"), entry("garbage"), entry("159.0.1+g5555555+chromium-159.0.1.1", sha1="short"))
        self.assertEqual(o["cef_version"], OLD)

    def test_changed_format_fails_loudly(self):
        p = self.d / "i.json"
        p.write_text("{}")
        r = run("latest", "--index", str(p), "--lock", str(self.d / "packaging/cef_version.lock"))
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("format", r.stderr)

    def test_apply_rewrites_everything_and_is_consistent(self):
        new = "156.0.40+gabcdef0+chromium-156.0.8078.200"
        sha256 = "e" * 64
        r = run("apply", "--cef-version", new, "--sha1", SHA1, "--sha256", sha256, "--root", str(self.d))
        self.assertEqual(r.returncode, 0, r.stderr)
        lock = (self.d / "packaging/cef_version.lock").read_text()
        self.assertIn(f"cef_version={new}", lock)
        self.assertIn(f"sha256={sha256}", lock)
        man = (self.d / "packaging/flatpak/io.github.tulip_labs.Iris.Cef.yml").read_text()
        self.assertIn(f"cef_binary_{new}_linux64_minimal.tar.bz2", man)
        self.assertIn(f"sha256: {sha256}", man)
        self.assertIn("CEF 156.0.40 (Chromium 156.0.8078.200)", man)
        self.assertNotIn(OLD, man)
        # Odin's own pinned checksum is untouched
        self.assertIn("65c9f6e97d6f8a30930e151f270ce5aeaa98fe8b2ba49fe067394e2af04f7618", man)
        old_v = (ROOT / "linux/src/version_cef.odin").read_text()
        new_v = (self.d / "linux/src/version_cef.odin").read_text()
        self.assertNotEqual(old_v, new_v)
        notes = (self.d / "packaging/release-notes-cef.md").read_text()
        ver = [l for l in new_v.splitlines() if l.startswith("CEF_VERSION")][0].split('"')[1]
        self.assertTrue(notes.startswith(f"Iris (Chromium) {ver}: Chromium 156.0.8078.200"))
        # the repo's own consistency check agrees
        (self.d / "packaging/check").mkdir(exist_ok=True)
        shutil.copy(ROOT / "packaging/check/versions-cef.sh", self.d / "packaging/check/versions-cef.sh")
        c = subprocess.run(["sh", "packaging/check/versions-cef.sh", f"cef-v{ver}"], cwd=self.d, capture_output=True, text=True)
        self.assertEqual(c.returncode, 0, c.stdout + c.stderr)
        # and the next check finds nothing to do
        o = self.latest(entry(new, sha1=SHA1))
        self.assertEqual(o["update"], "false")

    def test_apply_refuses_bad_checksums(self):
        r = run("apply", "--cef-version", OLD, "--sha1", "x", "--sha256", "y", "--root", str(self.d))
        self.assertNotEqual(r.returncode, 0)


if __name__ == "__main__":
    unittest.main()
