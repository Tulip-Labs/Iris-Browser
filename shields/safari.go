package shields

import (
	"encoding/json"
	"strings"
)

// WebKit (macOS WKWebView, Linux WebKitGTK) does not ask the app about each
// request the way WebView2 does: it takes a compiled list in Safari's
// content-blocker format. SafariJSON turns the engine's request rules into
// that list. Rules WebKit cannot express (regular expressions, separators in
// the middle of an address) are left out; hiding rules still apply, since
// Lite Go adds them to pages itself.

type safariRule struct {
	Trigger safariTrigger `json:"trigger"`
	Action  safariAction  `json:"action"`
}

type safariTrigger struct {
	URLFilter    string   `json:"url-filter"`
	ResourceType []string `json:"resource-type,omitempty"`
	LoadType     []string `json:"load-type,omitempty"`
	IfDomain     []string `json:"if-domain,omitempty"`
	UnlessDomain []string `json:"unless-domain,omitempty"`
}

type safariAction struct {
	Type string `json:"type"`
}

var safariKinds = []struct {
	k     Kind
	names []string
}{
	{KindScript, []string{"script"}}, {KindImage, []string{"image", "svg-document"}}, {KindXHR, []string{"raw", "fetch", "websocket"}},
	{KindMedia, []string{"media"}}, {KindPing, []string{"ping"}}, {KindOther, []string{"other"}},
}

// webkit never blocks style sheets or fonts either, like the other engines
var safariDefaultKinds = []string{"script", "image", "svg-document", "raw", "fetch", "websocket", "media", "ping", "other"}

// SafariJSON returns up to max request rules (blocks, then exceptions) plus
// extra blocked domains (the built-in list), in Safari's content-blocker format.
func (e *Engine) SafariJSON(max int, extraDomains []string) string {
	var blocks, allows []safariRule
	add := func(r *rule) {
		sr, ok := toSafari(r)
		if !ok {
			return
		}
		if r.flags&fException != 0 {
			allows = append(allows, sr)
		} else {
			blocks = append(blocks, sr)
		}
	}
	if e != nil {
		for _, rs := range e.block {
			for _, r := range rs {
				add(r)
			}
		}
		for _, r := range e.blockAny {
			add(r)
		}
		for _, rs := range e.allow {
			for _, r := range rs {
				add(r)
			}
		}
		for _, r := range e.allowAny {
			add(r)
		}
		for _, r := range e.pageAllow {
			if sr, ok := toSafari(r); ok && len(sr.Trigger.IfDomain) == 0 && strings.HasPrefix(sr.Trigger.URLFilter, hostPrefix) {
				// shields off on a page: ignore every block on that site
				d := strings.TrimSuffix(strings.TrimPrefix(sr.Trigger.URLFilter, hostPrefix), "[/:?&=]")
				d = strings.ReplaceAll(d, `\.`, ".")
				if !strings.ContainsAny(d, `\[]()*+?^$`) {
					allows = append(allows, safariRule{safariTrigger{URLFilter: ".*", IfDomain: []string{"*" + d}}, safariAction{"ignore-previous-rules"}})
				}
			}
		}
	}
	for _, d := range extraDomains {
		blocks = append(blocks, safariRule{safariTrigger{URLFilter: hostPrefix + regexQuote(d) + "[/:]", ResourceType: safariDefaultKinds}, safariAction{"block"}})
	}
	if len(blocks)+len(allows) > max {
		keep := max - len(allows)
		if keep < 0 {
			keep, allows = 0, allows[:max]
		}
		blocks = blocks[:keep]
	}
	var b strings.Builder
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(append(blocks, allows...))
	return strings.TrimSpace(b.String())
}

// the start of an address up to a host label: scheme, // and any subdomains
const hostPrefix = `^[a-z][a-z0-9.+-]*:(//)?([^/?#]+\.)?`

func regexQuote(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		if strings.IndexByte(`.+?()[]{}\|$^*`, c) >= 0 {
			b.WriteByte('\\')
		}
		b.WriteByte(c)
	}
	return b.String()
}

func toSafari(r *rule) (safariRule, bool) {
	if r.flags&fRegex != 0 || r.flags&fCase != 0 {
		return safariRule{}, false
	}
	var f strings.Builder
	switch {
	case r.flags&fHost != 0:
		f.WriteString(hostPrefix)
	case r.flags&fStart != 0:
		f.WriteString("^")
	}
	p := r.pat
	for i := 0; i < len(p); i++ {
		switch c := p[i]; c {
		case '*':
			f.WriteString(".*")
		case '^':
			if i == len(p)-1 {
				f.WriteString("[/:?&=]") // after a host or a word: WebKit addresses always go on
			} else {
				f.WriteString("[^a-zA-Z0-9_.%-]")
			}
		default:
			if strings.IndexByte(`.+?()[]{}\|$`, c) >= 0 {
				f.WriteByte('\\')
			}
			f.WriteByte(c)
		}
	}
	if r.flags&fEnd != 0 {
		f.WriteString("$")
	}
	if f.Len() < 4 {
		return safariRule{}, false
	}
	t := safariTrigger{URLFilter: f.String()}
	if r.kinds != 0 {
		for _, sk := range safariKinds {
			if r.kinds&sk.k != 0 {
				t.ResourceType = append(t.ResourceType, sk.names...)
			}
		}
		if len(t.ResourceType) == 0 {
			return safariRule{}, false
		}
	} else {
		t.ResourceType = safariDefaultKinds
	}
	switch {
	case r.flags&fThird != 0:
		t.LoadType = []string{"third-party"}
	case r.flags&fFirst != 0:
		t.LoadType = []string{"first-party"}
	}
	// WebKit takes either sites to apply on or sites to skip, not both
	switch {
	case len(r.dom) > 0:
		for _, d := range r.dom {
			if !strings.HasSuffix(d, ".*") {
				t.IfDomain = append(t.IfDomain, "*"+d)
			}
		}
		if len(t.IfDomain) == 0 {
			return safariRule{}, false
		}
	case len(r.notDom) > 0:
		for _, d := range r.notDom {
			if !strings.HasSuffix(d, ".*") {
				t.UnlessDomain = append(t.UnlessDomain, "*"+d)
			}
		}
	}
	act := "block"
	if r.flags&fException != 0 {
		act = "ignore-previous-rules"
	}
	return safariRule{t, safariAction{act}}, true
}
