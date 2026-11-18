package shell

import (
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestRelayGuards(t *testing.T) {
	t.Setenv("LITEGO_RELAY_LOCAL", "")
	for _, bad := range []string{
		"file:///etc/passwd", "ftp://example.com/v.mp4", "http://127.0.0.1:8080/v.mp4", "http://localhost/v.mp4",
		"http://192.168.1.1/cam.mp4", "http://10.0.0.5/a.mp4", "http://[::1]/a.mp4", "http://169.254.169.254/latest",
		"http://printer.local/a.mp4", "https://user:pw@example.com/a.mp4", "https://example.com/a b.mp4",
		"https://example.com/a.mp4\" ! filesink location=/tmp/x", "https://example.com/a.mp4|x", "",
	} {
		if _, ok := publicURL(bad); ok {
			t.Errorf("accepted %q", bad)
		}
	}
	for _, ip := range []string{"100.64.1.1", "0.0.0.0", "224.0.0.1", "fe80::1"} {
		if publicIP(net.ParseIP(ip)) {
			t.Errorf("%s counted as public", ip)
		}
	}
	if !publicIP(net.ParseIP("93.184.216.34")) {
		t.Error("a public address refused")
	}
	if got := cleanHeader("https://a/\r\nCookie: x"); got != "https://a/Cookie: x" {
		t.Errorf("header kept its line break: %q", got)
	}
	r := &relay{key: "k", busy: make(chan struct{}, 1)}
	for _, c := range []struct {
		dest, key string
		code      int
	}{{"empty", "k", 403}, {"", "k", 403}, {"video", "x", 404}, {"video", "k", 400}} {
		q := httptest.NewRequest(http.MethodGet, "/v?k="+c.key+"&u=http://127.0.0.1/a.mp4", nil)
		if c.dest != "" {
			q.Header.Set("Sec-Fetch-Dest", c.dest)
		}
		w := httptest.NewRecorder()
		r.ServeHTTP(w, q)
		if w.Code != c.code {
			t.Errorf("dest %q key %q: %d, want %d", c.dest, c.key, w.Code, c.code)
		}
		if w.Header().Get("Access-Control-Allow-Origin") != "" {
			t.Error("the relay must not let scripts read it")
		}
	}
}

func TestRunnableDownloads(t *testing.T) {
	for _, p := range []string{"/d/x.desktop", "/d/setup.SH", "/d/a.AppImage", "/d/a.exe", "/d/a.run"} {
		if !runnable(p) {
			t.Errorf("%s would be opened", p)
		}
	}
	for _, p := range []string{"/d/a.pdf", "/d/b.png", "/d/notes.txt", "/d/movie.mp4"} {
		if runnable(p) {
			t.Errorf("%s would not be opened", p)
		}
	}
}
