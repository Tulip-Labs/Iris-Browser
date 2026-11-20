package shields

import (
	"encoding/json"
	"strings"
	"testing"
)

const sample = `[Adblock Plus 2.0]
! Title: test
||doubleclick.net^
||ads.example.com^$third-party
/banner/*/ad_$image
||tracker.io/pixel.gif
@@||doubleclick.net/allowed/$script
||cdn.site.com/ads.js$script,domain=news.com|~sports.news.com
|https://exact.com/x.js|
/^https?:\/\/[a-z]+\.adserv\.net\//$script
||important.ad^$important
@@||important.ad^
||font.example^$font
@@||safe.org^$document
@@||nohide.org^$generichide
example.com##.sponsored-box
google.*##.g-ad
example.com#@#.ad-banner
##.ad-banner
###top-ad
##div[data-ad-slot]
##.text:has-text(Ad)
`

func engine() *Engine {
	e := New()
	e.Add(strings.NewReader(sample))
	return e
}

func TestNetwork(t *testing.T) {
	e := engine()
	cases := []struct {
		url, page string
		kind      Kind
		want      bool
	}{
		{"https://ad.doubleclick.net/x.js", "https://news.com/", KindScript, true},
		{"https://doubleclick.net.evil.com/x.js", "https://news.com/", KindScript, false},
		{"https://ad.doubleclick.net/allowed/x.js", "https://news.com/", KindScript, false},
		{"https://ads.example.com/a.js", "https://example.com/", KindScript, false}, // first party
		{"https://ads.example.com/a.js", "https://other.com/", KindScript, true},
		{"https://img.site/banner/top/ad_1.png", "https://x.com/", KindImage, true},
		{"https://img.site/banner/top/ad_1.png", "https://x.com/", KindScript, false},
		{"https://tracker.io/pixel.gif?id=1", "https://x.com/", KindImage, true},
		{"https://cdn.site.com/ads.js", "https://www.news.com/a", KindScript, true},
		{"https://cdn.site.com/ads.js", "https://sports.news.com/a", KindScript, false},
		{"https://cdn.site.com/ads.js", "https://other.com/", KindScript, false},
		{"https://exact.com/x.js", "https://a.com/", KindScript, true},
		{"https://exact.com/x.js?v=1", "https://a.com/", KindScript, false},
		{"https://abc.adserv.net/t.js", "https://a.com/", KindScript, true},
		{"https://important.ad/a.js", "https://a.com/", KindScript, true},
		{"https://ad.doubleclick.net/x.js", "https://safe.org/page", KindScript, false},
		{"https://www.youtube.com/watch?v=1", "https://news.com/", KindXHR, false},
	}
	for _, c := range cases {
		if got := e.Blocked(Request{URL: c.url, Page: c.page, Kind: c.kind}); got != c.want {
			t.Errorf("%s on %s: got %v want %v", c.url, c.page, got, c.want)
		}
	}
	if e.Rules == 0 || e.Hiding == 0 {
		t.Fatal("nothing parsed")
	}
}

func TestCosmetic(t *testing.T) {
	e := engine()
	s := e.SiteSelectors("https://www.example.com/a")
	if !contains(s, ".sponsored-box") || !contains(s, "div[data-ad-slot]") {
		t.Fatalf("site selectors: %v", s)
	}
	if g := e.SiteSelectors("https://www.google.com.co/search"); !contains(g, ".g-ad") {
		t.Fatalf("google.* rules: %v", g)
	}
	gen := e.GenericSelectors("https://www.example.com/", []string{"ad-banner", "x"}, []string{"top-ad"})
	if contains(gen, ".ad-banner") || !contains(gen, "#top-ad") {
		t.Fatalf("generic with site exception: %v", gen)
	}
	if g := e.GenericSelectors("https://nohide.org/", nil, []string{"top-ad"}); len(g) != 0 {
		t.Fatalf("generichide: %v", g)
	}
	for _, sel := range e.SiteSelectors("https://x.com/") {
		if strings.Contains(sel, "has-text") {
			t.Fatal("procedural selectors must be skipped")
		}
	}
}

func TestClean(t *testing.T) {
	cases := map[string]string{
		"https://a.com/p?id=3&utm_source=x&utm_medium=y&fbclid=Z": "https://a.com/p?id=3",
		"https://a.com/p?q=1": "https://a.com/p?q=1",
		"https://www.google.com/url?q=https%3A%2F%2Fb.com%2Fx%3Futm_campaign%3Dz&sa=U": "https://b.com/x",
		"https://www.google.com/amp/s/www.site.com/news/1.amp":                         "https://www.site.com/news/1.amp",
		"https://youtu.be/abc?si=TRACK":                                                "https://youtu.be/abc",
		"https://www.youtube.com/watch?v=abc&pp=xyz&t=10":                              "https://www.youtube.com/watch?v=abc&t=10",
		"https://l.facebook.com/l.php?u=https%3A%2F%2Fc.org%2F&h=AT0":                  "https://c.org/",
	}
	for in, want := range cases {
		if got := Clean(in); got != want {
			t.Errorf("Clean(%s) = %s, want %s", in, got, want)
		}
	}
}

func contains(l []string, s string) bool {
	for _, x := range l {
		if x == s {
			return true
		}
	}
	return false
}

func BenchmarkBlocked(b *testing.B) {
	e := engine()
	for i := 0; i < 20000; i++ {
		e.AddLine("||adhost" + itoa(i) + ".com^")
	}
	q := Request{URL: "https://cdn.example.org/assets/app.bundle.min.js?v=1234", Page: "https://www.example.org/", Kind: KindScript}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		e.Blocked(q)
	}
}

func itoa(i int) string {
	s := ""
	for {
		s = string(rune('0'+i%10)) + s
		i /= 10
		if i == 0 {
			return s
		}
	}
}

// The shield as WebKit content rules: host rules, kinds, third party,
// exceptions after blocks, and the sites that are never blocked.
func TestContentRules(t *testing.T) {
	e := New()
	e.Add(strings.NewReader("||doubleclick.net^\n||ads.example.com^$script,third-party\n/banner/ad.\n@@||doubleclick.net/ok/$script\n/^regex$/\n"))
	js := ContentRules(e, ContentRuleSet{Domains: []string{"tracker.test"}, Never: []string{"accounts.google.com"}, Off: []string{"mysite.org"}})
	var rules []struct {
		Trigger map[string]any        `json:"trigger"`
		Action  struct{ Type string } `json:"action"`
	}
	if err := json.Unmarshal(js, &rules); err != nil {
		t.Fatal(err)
	}
	var kinds []string
	lastBlock, firstAllow := -1, len(rules)
	for i, r := range rules {
		kinds = append(kinds, r.Action.Type)
		if r.Action.Type == "block" {
			lastBlock = i
		} else if i < firstAllow {
			firstAllow = i
		}
	}
	if lastBlock > firstAllow {
		t.Fatalf("exceptions must follow every block: %v", kinds)
	}
	s := string(js)
	for _, want := range []string{`doubleclick\\.net`, `tracker\\.test`, `"third-party"`, `banner`, `accounts\\.google\\.com`, `"*mysite.org"`} {
		if !strings.Contains(s, want) {
			t.Errorf("missing %s in %s", want, s)
		}
	}
	if strings.Contains(s, "regex") {
		t.Error("regular-expression rules are left out")
	}
	if len(rules) != 7 {
		t.Errorf("%d rules: %v", len(rules), kinds)
	}
}
