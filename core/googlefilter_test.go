package core

import (
	"strings"
	"testing"
)

func TestGoogleFilters(t *testing.T) {
	base := "https://www.google.com/search?q=go+generics"
	if _, ok := ReadGoogleFilters("https://example.com/search?q=x"); ok {
		t.Error("not Google")
	}
	if _, ok := ReadGoogleFilters(base + "&udm=2"); ok {
		t.Error("image searches have no filters")
	}
	if _, ok := ReadGoogleFilters(base + "&udm=50"); ok {
		t.Error("AI Mode has no filters")
	}
	f, ok := ReadGoogleFilters(base)
	if !ok || f != (GoogleFilters{}) {
		t.Fatalf("plain search: %+v %v", f, ok)
	}
	for _, want := range []GoogleFilters{
		{Time: "w"},
		{Exact: true},
		{Time: "y", Exact: true, Type: "forums"},
		{Type: "news"},
		{Type: "videos", Time: "d"},
		{Type: "pdf", All: true},
		{All: true},
	} {
		u := want.Apply(base + "&start=10")
		got, ok := ReadGoogleFilters(u)
		if !ok || got != want {
			t.Errorf("%+v: %s read back as %+v", want, u, got)
		}
		if strings.Contains(u, "start=") {
			t.Errorf("%s: a new filter starts at the first page", u)
		}
		// and back to no filters: the words unchanged
		back := GoogleFilters{}.Apply(u)
		if g, _ := ReadGoogleFilters(back); g != (GoogleFilters{}) || !strings.Contains(back, "q=go+generics") || strings.Contains(back, "filetype") {
			t.Errorf("%s: cleared to %s", u, back)
		}
	}
	if u := (GoogleFilters{Type: "pdf"}).Apply(base); !strings.Contains(u, "q=go+generics+filetype%3Apdf") {
		t.Errorf("PDFs: %s", u)
	}
}

func TestGoogleCleanScript(t *testing.T) {
	s := GoogleCleanScript()
	for _, want := range []string{`"wikipedia.org":"Reference"`, `"softonic.com":true`, `"amazon.com":true`, "people also ask", "ai overview"} {
		if !strings.Contains(s, want) {
			t.Errorf("the script has no %s", want)
		}
	}
	if strings.Contains(s, "%!") {
		t.Error("a formatting mistake in the script")
	}
}
