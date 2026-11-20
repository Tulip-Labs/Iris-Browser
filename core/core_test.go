package core

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestResolve(t *testing.T) {
	cases := map[string]string{
		"example.com":        "https://example.com",
		"localhost:8080/x":   "http://localhost:8080/x",
		"192.168.1.1":        "http://192.168.1.1",
		"https://go.dev/doc": "https://go.dev/doc",
		"yt lofi beats":      "https://www.youtube.com/results?search_query=lofi+beats",
		"   ":                "",
	}
	for in, want := range cases {
		if got := Resolve(in, ModeAI); got != want {
			t.Errorf("Resolve(%q) = %q, want %q", in, got, want)
		}
	}
	// every search is a Google AI Mode one, asked for the best current sources,
	// whatever mode an older setting names
	for _, m := range []Mode{ModeAI, ModeWeb, ModeImages} {
		got := Resolve("how do rainbows form", m)
		if !strings.HasPrefix(got, "https://www.google.com/search?gl=us&hl=en&udm=50&q=how+do+rainbows+form%0A%0A") {
			t.Errorf("search in mode %d: %s", m, got)
		}
		if q, ok := AIQuery(got); !ok || q != "how do rainbows form" {
			t.Errorf("AIQuery(%s) = %q %v", got, q, ok)
		}
		if !strings.Contains(AIPrompt("x"), "high-quality") || !strings.Contains(AIPrompt("x"), "concise") {
			t.Error("the instruction asks for good sources and a clear answer")
		}
	}
	if _, ok := AIQuery("https://www.google.com/search?q=cats&udm=14"); ok {
		t.Error("a plain web search is not an AI Mode one")
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
	t.Cleanup(h.Close) // before the folder is removed: Windows keeps open files
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
	h.Close() // writes are asynchronous: this waits for them
	h2 := OpenHistory(dir)
	t.Cleanup(h2.Close)
	h2.Wait()
	if len(h2.Suggest("go.dev", 5)) != 1 {
		t.Fatal("history did not persist in SQLite")
	}
}

func TestPlan(t *testing.T) {
	if p := Plan(4096, "balanced"); p.Live != 2 || !p.Low || p.UnloadAfter > 30 {
		t.Fatalf("4 GB: %+v", p)
	}
	if p := Plan(8192, "balanced"); p.Live != 3 || p.Low || p.UnloadAfter > 60 {
		t.Fatalf("8 GB: %+v", p)
	}
	if p := Plan(8192, "saver"); p.Live != 2 || !p.Low || p.UnloadAfter > 20 {
		t.Fatalf("8 GB saver: %+v", p)
	}
	if p := Plan(16384, "speed"); p.Live != 8 {
		t.Fatalf("16 GB speed: %+v", p)
	}
}

func TestContainersLegacy(t *testing.T) {
	var s Settings
	if err := json.Unmarshal([]byte(`{"containers":["Work",{"name":"Bank","icon":"dollar","color":"green"}]}`), &s); err != nil {
		t.Fatal(err)
	}
	if len(s.Containers) != 2 || s.Containers[0].Name != "Work" || s.Containers[1].Icon != "dollar" {
		t.Fatalf("%+v", s.Containers)
	}
}

func TestGoogleQuery(t *testing.T) {
	q, m, ok := GoogleQuery(ModeImages.URL("red pandas"))
	if !ok || q != "red pandas" || m != ModeImages {
		t.Fatal(q, m, ok)
	}
	if _, _, ok := GoogleQuery("https://www.youtube.com/results?search_query=x"); ok {
		t.Fatal("youtube is not google")
	}
}

func TestParsers(t *testing.T) {
	web, _ := ParseWeb(`{"web":[{"t":"Go","u":"https://go.dev/","s":"Build simple software"},{"t":"","u":"x"}]}`)
	if len(web) != 1 || web[0].Site != "go.dev" {
		t.Fatalf("%+v", web)
	}
	ai := ParseAI(`{"ai":"red pandas\nAI Mode\nThinking\nRed pandas live in the Himalayas.\nShow more\n3 sites\nThey eat bamboo.","src":[{"t":"WWF","u":"https://wwf.org"}]}`, "red pandas")
	if ai.Text != "Red pandas live in the Himalayas.\nThey eat bamboo." || len(ai.Sources) != 1 {
		t.Fatalf("%q", ai.Text)
	}
	html := `<script>var ytInitialData = {"contents":{"x":[{"videoRenderer":{"videoId":"abc","title":{"runs":[{"text":"Lo-fi"}]},"ownerText":{"runs":[{"text":"Chill"}]},"lengthText":{"simpleText":"1:02:03"}}}]}};</script>`
	v, err := ParseYouTube(html)
	if err != nil || len(v) != 1 || v[0].Title != "Lo-fi" || v[0].Length != "1:02:03" {
		t.Fatal(v, err)
	}
	p := PagePrompt("Summarize", "T", "https://a.b/", strings.Repeat("word ", 1000), "")
	if len(p) > 1800 || !strings.Contains(p, "https://a.b/") {
		t.Fatal(len(p))
	}
}

func TestParseAIBlocks(t *testing.T) {
	js := `{"blocks":[
 {"k":"p","t":"red pandas","c":[]},
 {"k":"p","t":"**Red pandas** are small mammals of the **eastern Himalayas**.","c":[1,2]},
 {"k":"p","t":"**What they eat**","c":[]},
 {"k":"li","t":"Mostly bamboo","c":[2,9]},
 {"k":"p","t":"Show more","c":[]}],
 "src":[{"t":"Red panda - Wikipedia","u":"https://en.wikipedia.org/wiki/Red_panda"},{"t":"WWF","u":"https://www.worldwildlife.org/"}],
 "ai":"Red pandas are small mammals of the eastern Himalayas.\nWhat they eat\nMostly bamboo"}`
	r := ParseAI(js, "red pandas")
	if len(r.Blocks) != 3 {
		t.Fatalf("%+v", r.Blocks)
	}
	if r.Blocks[1].Kind != "h" || r.Blocks[1].Text != "What they eat" {
		t.Fatalf("bold line should be a heading: %+v", r.Blocks[1])
	}
	if len(r.Blocks[2].Cites) != 1 || r.Blocks[0].Cites[1] != 2 {
		t.Fatalf("cites: %+v", r.Blocks)
	}
	if !strings.HasPrefix(r.Text, "Red pandas are small") {
		t.Fatalf("%q", r.Text)
	}
}

func TestRank(t *testing.T) {
	in := []WebResult{
		{Title: "Top 10 best red panda plushies of 2026", URL: "https://www.toyreviews.example/plush"},
		{Title: "Red panda plush", URL: "https://www.amazon.com/dp/1"},
		{Title: "Red panda - Wikipedia", URL: "https://en.wikipedia.org/wiki/Red_panda"},
		{Title: "Red panda facts", URL: "https://www.nationalgeographic.com/a"},
		{Title: "Red panda page 2", URL: "https://en.wikipedia.org/wiki/Ailurus"},
		{Title: "Red panda page 3", URL: "https://de.wikipedia.org/wiki/Katzenbär"},
		{Title: "Blog", URL: "https://pandas.example/blog"},
	}
	r := Rank(in, "red pandas", map[string]int{"example": 0, "pandas.example": -2})
	if r[0].Host() != "en.wikipedia.org" || r[0].Label != "Reference" {
		t.Fatalf("reference first: %+v", r[0])
	}
	n := 0
	for _, x := range r {
		if strings.Contains(x.URL, "wikipedia") {
			n++
		}
		if strings.Contains(x.URL, "pandas.example") {
			t.Fatal("a hidden site must not show")
		}
	}
	if n != 2 {
		t.Fatalf("at most two per site, got %d", n)
	}
	if r[len(r)-1].Host() != "www.amazon.com" && r[len(r)-1].Host() != "www.toyreviews.example" {
		t.Fatalf("shops and listicles sink: %+v", r)
	}
	if b := Rank(in, "buy red panda plush", nil); b[len(b)-1].Host() == "www.amazon.com" {
		t.Fatal("shops are fine when buying")
	}
}
