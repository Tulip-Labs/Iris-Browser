package update

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
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

func TestLatest(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/repos/"+Repo+"/releases/latest" {
			http.NotFound(w, r)
			return
		}
		json.NewEncoder(w).Encode(Release{Tag: "v9.9.9"})
	}))
	defer srv.Close()
	old := API
	API = srv.URL
	defer func() { API = old }()
	r, err := Latest(context.Background())
	if err != nil || r.Version() != "9.9.9" {
		t.Fatalf("latest: %v %q", err, r.Version())
	}
}

// Flatpak, Snap and Nix bring Iris's updates; each kind names what does.
func TestKinds(t *testing.T) {
	for _, k := range []Kind{KindFlatpak, KindSnap, KindNix, KindDev} {
		if k.Managed() == "" {
			t.Errorf("%s: nothing named to update it", k)
		}
	}
}
