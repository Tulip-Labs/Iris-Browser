package core

import (
	"strings"
	"testing"
)

func TestTypedSchemes(t *testing.T) {
	for in, want := range map[string]string{
		"https://example.com": "https://example.com",
		"file:///home/x.pdf":  "file:///home/x.pdf",
		"about:blank":         "about:blank",
		"localhost:8080":      "http://localhost:8080",
		"example.com":         "https://example.com",
	} {
		if got := Resolve(in, ModeWeb); got != want {
			t.Errorf("Resolve(%q) = %q, want %q", in, got, want)
		}
	}
	for _, in := range []string{"javascript:alert(document.cookie)", "JaVaScRiPt:fetch('//x')", "note: buy milk", "data:text/html,<script>x</script>", "vbscript:x"} {
		if got := Resolve(in, ModeWeb); !strings.Contains(got, "google.") {
			t.Errorf("Resolve(%q) = %q, want a search", in, got)
		}
	}
}
