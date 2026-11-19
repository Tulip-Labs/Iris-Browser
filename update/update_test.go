package update

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
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

func TestFetch(t *testing.T) {
	name := AssetName(KindSetup, "9.9.9")
	pkg := []byte("the new installer")
	sum := sha256.Sum256(pkg)
	bad := false
	mux := http.NewServeMux()
	var srv *httptest.Server
	mux.HandleFunc("/repos/"+Repo+"/releases/latest", func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(Release{Tag: "v9.9.9", Assets: []Asset{
			{Name: name, URL: srv.URL + "/f/pkg", Size: int64(len(pkg))},
			{Name: "SHA256SUMS", URL: srv.URL + "/f/sums"},
		}})
	})
	mux.HandleFunc("/f/pkg", func(w http.ResponseWriter, r *http.Request) {
		if bad {
			w.Write(append([]byte("x"), pkg...))
			return
		}
		w.Write(pkg)
	})
	mux.HandleFunc("/f/sums", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("0000000000000000000000000000000000000000000000000000000000000000  other.exe\n" + hex.EncodeToString(sum[:]) + "  " + name + "\n"))
	})
	srv = httptest.NewServer(mux)
	defer srv.Close()
	API = srv.URL
	defer func() { API = "https://api.github.com" }()

	r, err := Latest(context.Background())
	if err != nil || r.Version() != "9.9.9" || !Newer(r.Version(), "1.0.3") {
		t.Fatalf("latest: %+v %v", r, err)
	}
	var last float32
	p, err := Fetch(context.Background(), r, KindSetup, t.TempDir(), func(f float32) { last = f })
	if err != nil || last != 1 {
		t.Fatalf("fetch: %v (progress %v)", err, last)
	}
	if b, _ := os.ReadFile(p); string(b) != string(pkg) {
		t.Fatalf("downloaded %q", b)
	}
	// a file that does not match its checksum is refused
	bad = true
	if _, err := Fetch(context.Background(), r, KindSetup, t.TempDir(), nil); err == nil {
		t.Fatal("a corrupted download was accepted")
	}
}

func TestKinds(t *testing.T) {
	if !KindSetup.CanSelf() || AssetName(KindSetup, "1.2.3") == "" {
		t.Error("Iris Setup copies should update themselves")
	}
	// on Linux, Flatpak, Snap and Nix update Iris
	for _, k := range []Kind{KindFlatpak, KindSnap, KindNix, KindStore, KindPortable, KindDev} {
		if k.CanSelf() {
			t.Errorf("%s is updated by %s", k, k.Managed())
		}
	}
}

func TestFetchGuards(t *testing.T) {
	pkg := []byte("the new installer, longer than it was announced")
	sum := sha256.Sum256(pkg)
	name := AssetName(KindSetup, "9.9.9")
	mux := http.NewServeMux()
	mux.HandleFunc("/f/pkg", func(w http.ResponseWriter, r *http.Request) { w.Write(pkg) })
	mux.HandleFunc("/f/sums", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(hex.EncodeToString(sum[:]) + "  " + name + "\n"))
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()
	API = srv.URL
	defer func() { API = "https://api.github.com" }()
	// more bytes than the release announced: refused, nothing left behind
	dir := t.TempDir()
	r := Release{Tag: "v9.9.9", Assets: []Asset{{Name: name, URL: srv.URL + "/f/pkg", Size: 10}, {Name: "SHA256SUMS", URL: srv.URL + "/f/sums"}}}
	if _, err := Fetch(context.Background(), r, KindSetup, dir, nil); err == nil {
		t.Fatal("a download larger than announced was accepted")
	}
	if ents, _ := os.ReadDir(dir); len(ents) != 0 {
		t.Fatalf("left behind: %v", ents)
	}
	// plain HTTP from anywhere but the API's own address is refused
	other := "http://downloads.example.invalid/pkg"
	r.Assets[0] = Asset{Name: name, URL: other, Size: int64(len(pkg))}
	if _, err := Fetch(context.Background(), r, KindSetup, dir, nil); err == nil {
		t.Fatal("an update over plain HTTP was accepted")
	}
	if secureURL(other) || !secureURL("https://github.com/x") || secureURL("ftp://x/y") || secureURL("https:///nohost") {
		t.Fatal("secureURL")
	}
}
