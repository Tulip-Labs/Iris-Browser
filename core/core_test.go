package core

import (
	"strings"
	"testing"
	"time"
)

func TestResolve(t *testing.T) {
	cases := map[string]string{
		"example.com":          "https://example.com",
		"localhost:8080/x":     "http://localhost:8080/x",
		"192.168.1.1":          "http://192.168.1.1",
		"https://go.dev/doc":   "https://go.dev/doc",
		"yt lofi beats":        "https://www.youtube.com/results?search_query=lofi+beats",
		"how do rainbows form": "https://www.google.com/search?gl=us&hl=en&udm=50&q=how+do+rainbows+form",
		"   ":                  "",
	}
	for in, want := range cases {
		if got := Resolve(in, ModeAI); got != want {
			t.Errorf("Resolve(%q) = %q, want %q", in, got, want)
		}
	}
	if got := Resolve("cats", ModeImages); !strings.Contains(got, "udm=2") {
		t.Errorf("images mode: %s", got)
	}
}

func TestHTTPS(t *testing.T) {
	if HTTPSUpgrade("http://example.com/a") != "https://example.com/a" {
		t.Error("upgrade")
	}
	if HTTPSUpgrade("http://192.168.0.5/") != "" || HTTPSUpgrade("https://x.com") != "" {
		t.Error("no upgrade for local or https")
	}
}

func TestShield(t *testing.T) {
	s := NewShield()
	s.Wait()
	if s.Size() < 100000 {
		t.Fatalf("list size %d", s.Size())
	}
	page := "https://www.example.com/"
	if s.Allow("https://googleads.g.doubleclick.net/pagead/x.js", page) {
		t.Error("doubleclick must be blocked")
	}
	if !s.Allow("https://www.example.com/app.js", page) {
		t.Error("first party must load")
	}
	if !s.Allow("https://rr3---sn-abc.googlevideo.com/videoplayback?x=1", "https://www.youtube.com/watch?v=1") {
		t.Error("YouTube media must always load")
	}
	if s.Allow("https://www.youtube.com/youtubei/v1/log_event?x", "https://www.youtube.com/") {
		t.Error("YouTube telemetry is blockable")
	}
	if !s.Allow("https://accounts.google.com/x", page) {
		t.Error("sign-in is never blocked")
	}
	s.SetSiteOff("www.example.com", true)
	if !s.Allow("https://googleads.g.doubleclick.net/x.js", page) {
		t.Error("site switch off")
	}
}

func BenchmarkShieldAllow(b *testing.B) {
	s := NewShield()
	s.Wait()
	for i := 0; i < b.N; i++ {
		s.Allow("https://static.cdn.example-images.com/a/b/c.png", "https://news.example.com/")
	}
}

func TestHistory(t *testing.T) {
	dir := t.TempDir()
	h := OpenHistory(dir)
	h.Wait()
	h.Add("https://www.youtube.com/watch?v=1", "Lo-fi", true)
	h.Add("https://www.youtube.com/", "YouTube", true)
	h.Add("https://www.youtube.com/", "YouTube", true)
	h.Add("https://go.dev/doc/", "Go docs", true)
	if s := h.Suggest("you", 5); len(s) == 0 || Host(s[0].URL) != "www.youtube.com" {
		t.Fatalf("suggest: %+v", s)
	}
	if top := h.Top(5); len(top) != 2 {
		t.Fatalf("top per host: %+v", top)
	}
	time.Sleep(300 * time.Millisecond) // writes are asynchronous
	h2 := OpenHistory(dir)
	h2.Wait()
	if len(h2.Suggest("go.dev", 5)) != 1 {
		t.Fatal("history did not persist in SQLite")
	}
}

func TestPlan(t *testing.T) {
	if p := Plan(4096, "balanced"); p.Live != 4 || !p.Low {
		t.Fatalf("4 GB: %+v", p)
	}
	if p := Plan(8192, "balanced"); p.Live != 6 || p.Low {
		t.Fatalf("8 GB: %+v", p)
	}
	if p := Plan(8192, "saver"); p.Live != 3 || !p.Low || p.SleepAfter != 30 {
		t.Fatalf("8 GB saver: %+v", p)
	}
	if p := Plan(16384, "speed"); p.Live != 24 {
		t.Fatalf("16 GB speed: %+v", p)
	}
}
