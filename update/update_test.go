package update

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestNewer(t *testing.T) {
	cases := []struct {
		a, b string
		want bool
	}{
		{"v1.0.4", "1.0.3", true}, {"1.0.10", "1.0.9", true}, {"1.1", "1.0.9", true},
		{"1.0.3", "1.0.3", false}, {"v1.0.2", "1.0.3", false}, {"2.0.0-beta", "1.9", true}, {"1.0", "1.0.0", false},
	}
	for _, c := range cases {
		if got := Newer(c.a, c.b); got != c.want {
			t.Errorf("Newer(%q, %q) = %v", c.a, c.b, got)
		}
	}
}

func tarball(t *testing.T, files map[string]string) []byte {
	var b bytes.Buffer
	zw := gzip.NewWriter(&b)
	tw := tar.NewWriter(zw)
	for name, body := range files {
		tw.WriteHeader(&tar.Header{Name: name, Mode: 0o755, Size: int64(len(body)), Typeflag: tar.TypeReg})
		tw.Write([]byte(body))
	}
	tw.Close()
	zw.Close()
	return b.Bytes()
}

func TestFetchAndReplace(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("the home-folder copy is a Linux install")
	}
	name := AssetName(KindUser, "9.9.9")
	tgz := tarball(t, map[string]string{
		"LiteGo-linux-x86_64/lite-go-browser":        "new program",
		"LiteGo-linux-x86_64/lite-go-browser.sha256": "new record",
		"LiteGo-linux-x86_64/libcef.so":              "new engine",
		"LiteGo-linux-x86_64/lite-go-helper":         "new helper",
		"LiteGo-linux-x86_64/install.sh":             "not copied",
		"LiteGo-linux-x86_64/../escape":              "never written",
	})
	sum := sha256.Sum256(tgz)
	bad := false
	mux := http.NewServeMux()
	var srv *httptest.Server
	mux.HandleFunc("/repos/"+Repo+"/releases/latest", func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(Release{Tag: "v9.9.9", Assets: []Asset{
			{Name: name, URL: srv.URL + "/f/pkg", Size: int64(len(tgz))},
			{Name: "SHA256SUMS", URL: srv.URL + "/f/sums"},
		}})
	})
	mux.HandleFunc("/f/pkg", func(w http.ResponseWriter, r *http.Request) {
		if bad {
			w.Write(append([]byte("x"), tgz...))
			return
		}
		w.Write(tgz)
	})
	mux.HandleFunc("/f/sums", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("0000000000000000000000000000000000000000000000000000000000000000  other.deb\n" + hex.EncodeToString(sum[:]) + "  " + name + "\n"))
	})
	srv = httptest.NewServer(mux)
	defer srv.Close()
	API = srv.URL
	defer func() { API = "https://api.github.com" }()

	r, err := Latest(context.Background())
	if err != nil || r.Version() != "9.9.9" || !Newer(r.Version(), "1.0.3") {
		t.Fatalf("latest: %+v %v", r, err)
	}
	dir := t.TempDir()
	var last float32
	p, err := Fetch(context.Background(), r, KindUser, dir, func(f float32) { last = f })
	if err != nil || last != 1 {
		t.Fatalf("fetch: %v (progress %v)", err, last)
	}
	// the program's own folder, as install.sh makes it
	exe := filepath.Join(dir, "lib", "lite-go-browser", "lite-go-browser")
	os.MkdirAll(filepath.Dir(exe), 0o755)
	os.WriteFile(exe, []byte("old program"), 0o755)
	os.WriteFile(exe+".sha256", []byte("old record"), 0o644)
	os.WriteFile(filepath.Join(filepath.Dir(exe), "libcef.so"), []byte("old engine"), 0o644)
	if err := replaceFromTar(p, exe); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(exe); string(b) != "new program" {
		t.Fatalf("program: %q", b)
	}
	if b, _ := os.ReadFile(exe + ".sha256"); string(b) != "new record" {
		t.Fatalf("record: %q", b)
	}
	if _, err := os.Stat(filepath.Join(filepath.Dir(exe), "install.sh")); err == nil {
		t.Fatal("install.sh was copied into the program folder")
	}
	if _, err := os.Stat(filepath.Join(dir, "lib", "escape")); err == nil {
		t.Fatal("a path in the archive left the program folder")
	}
	// a file that does not match its checksum is refused
	bad = true
	if _, err := Fetch(context.Background(), r, KindUser, t.TempDir(), nil); err == nil {
		t.Fatal("a corrupted download was accepted")
	}
}

func TestKinds(t *testing.T) {
	for _, k := range []Kind{KindUser, KindDeb, KindRPM, KindFlatpak, KindSetup} {
		if !k.CanSelf() || AssetName(k, "1.2.3") == "" {
			t.Errorf("%s should update itself", k)
		}
	}
	for _, k := range []Kind{KindOSTree, KindArch, KindFlathub, KindNix, KindStore, KindPortable, KindDev} {
		if k.CanSelf() {
			t.Errorf("%s is updated by %s", k, k.Managed())
		}
	}
	if got := AssetName(KindDeb, "1.2.3"); runtime.GOARCH == "amd64" && got != "lite-go-browser_1.2.3_amd64.deb" {
		t.Errorf("deb name %s", got)
	}
	if got := AssetName(KindRPM, "1.2.3"); runtime.GOARCH == "amd64" && got != "lite-go-browser-1.2.3-1.x86_64.rpm" {
		t.Errorf("rpm name %s", got)
	}
}
