package route

import (
	"testing"
	"time"
)

func TestPick(t *testing.T) {
	r := Open("")
	for _, c := range []struct {
		url  string
		want Engine
	}{
		{"https://en.wikipedia.org/wiki/Red_panda", Light},
		{"https://www.google.com/search?q=red+pandas", Light},
		{"https://example.com/blog/post", Light},
		{"about:blank", Light},
		{"", Light},
		{"https://www.youtube.com/watch?v=x", Heavy},
		{"https://m.youtube.com/", Heavy},
		{"https://youtu.be/x", Heavy},
		{"https://www.linkedin.com/feed/", Heavy},
		{"https://facebook.com/", Heavy},
		{"https://accounts.google.com/signin", Heavy},
		{"https://docs.google.com/document/d/1", Heavy},
		{"https://github.com/login", Heavy},
		{"https://github.com/Tulip-Labs/Iris-Browser", Light},
		{"https://notyoutube.com/", Light}, // not a subdomain
		{"file:///home/me/a.html", Heavy},
		{"view-source:https://example.com", Heavy},
	} {
		if got := r.Pick(c.url); got != c.want {
			t.Errorf("Pick(%q) = %v, want %v", c.url, got, c.want)
		}
	}
}

func TestFailedAndChoice(t *testing.T) {
	dir := t.TempDir()
	r := Open(dir)
	now := time.Unix(1_800_000_000, 0)
	r.now = func() time.Time { return now }
	u := "https://heavy-blog.example/post"
	if r.Pick(u) != Light {
		t.Fatal("a blog starts in WebKit")
	}
	r.Failed(u)
	if r.Pick("https://heavy-blog.example/other") != Heavy {
		t.Error("a site WebKit failed on goes to the heavy engine")
	}
	// remembered across starts
	r2 := Open(dir)
	r2.now = r.now
	if r2.Pick(u) != Heavy {
		t.Error("failures are kept")
	}
	// tried in WebKit again after a month
	now = now.Add(31 * 24 * time.Hour)
	if r2.Pick(u) != Light {
		t.Error("a failure is forgotten after a month")
	}
	// the reader's choice wins both ways
	r2.Choose("https://www.youtube.com/", Light)
	if r2.Pick("https://www.youtube.com/watch") != Light {
		t.Error("the reader moved YouTube to WebKit")
	}
	r2.Choose("https://en.wikipedia.org/", Heavy)
	if r2.Pick("https://en.wikipedia.org/wiki/X") != Heavy {
		t.Error("the reader moved Wikipedia to the heavy engine")
	}
	r2.Forget("https://en.wikipedia.org/")
	if r2.Pick("https://en.wikipedia.org/wiki/X") != Light {
		t.Error("forgotten choice")
	}
}

func TestExtraHosts(t *testing.T) {
	t.Setenv("IRIS_HEAVY_HOSTS", "127.0.0.3, heavy.test")
	r := Open("")
	if r.Pick("http://127.0.0.3:8766/x") != Heavy || r.Pick("https://a.heavy.test/") != Heavy || r.Pick("http://127.0.0.2:8766/") != Light {
		t.Error("IRIS_HEAVY_HOSTS")
	}
}
