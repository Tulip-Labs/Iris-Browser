package shields

import (
	"encoding/json"
	"sort"
	"strings"
)

// Content rules: the shield as WebKit's content blockers (the JSON format
// Safari and WebKitGTK compile into a matcher of their own). WebKit pages
// do not ask Iris about each request; WebKit matches these rules itself,
// inside the engine, before a request leaves.
//
// Only the rules WebKit's regular expressions can say are converted: rules
// anchored to a host (||ads.example.com^), to the start of the address, or
// a plain piece of an address, with their kinds, first or third party and
// domains. Regular-expression rules are left out. Exceptions follow every
// block, as "ignore-previous-rules".

// ContentRuleSet is what goes into one compiled list.
type ContentRuleSet struct {
	// Domains are blocked whole, every kind of request to them and their
	// subdomains (core.Shield's list).
	Domains []string
	// Never are hosts never blocked: sign-in, messaging, human checks.
	Never []string
	// Off are sites where the shield is off: nothing on their pages is blocked.
	Off []string
	// MaxRules caps the list (WebKit compiles every rule into one machine).
	MaxRules int
}

type wkTrigger struct {
	URLFilter    string   `json:"url-filter"`
	ResourceType []string `json:"resource-type,omitempty"`
	LoadType     []string `json:"load-type,omitempty"`
	IfDomain     []string `json:"if-domain,omitempty"`
	UnlessDomain []string `json:"unless-domain,omitempty"`
}

type wkAction struct {
	Type string `json:"type"`
}

type wkRule struct {
	Trigger wkTrigger `json:"trigger"`
	Action  wkAction  `json:"action"`
}

// the kinds Iris blocks, as WebKit names them (style sheets, fonts and whole
// pages are never blocked)
var wkAsked = []string{"script", "image", "raw", "media"}

func wkKinds(k Kind) []string {
	if k == 0 {
		return wkAsked
	}
	var out []string
	if k&KindScript != 0 {
		out = append(out, "script")
	}
	if k&KindImage != 0 {
		out = append(out, "image")
	}
	if k&(KindXHR|KindPing|KindOther) != 0 {
		out = append(out, "raw")
	}
	if k&KindMedia != 0 {
		out = append(out, "media")
	}
	return out
}

const wkScheme = `^[a-z][a-z0-9.+-]*://`

// wkHost is the url-filter for a host and its subdomains.
func wkHost(h string) string {
	return wkScheme + `([^/:?#]*\.)?` + wkEscape(h) + `[/:?#]`
}

func wkEscape(s string) string {
	var b strings.Builder
	for _, c := range s {
		switch c {
		case '.', '+', '?', '(', ')', '[', ']', '{', '}', '\\', '$', '|', '/':
			b.WriteByte('\\')
			b.WriteRune(c)
		default:
			b.WriteRune(c)
		}
	}
	return b.String()
}

// wkPattern turns a filter pattern into WebKit's regular expression, or ""
// where it cannot.
func wkPattern(r *rule) string {
	if r.flags&fRegex != 0 || r.pat == "" || len(r.pat) < 3 {
		return ""
	}
	var b strings.Builder
	switch {
	case r.flags&fHost != 0:
		b.WriteString(wkScheme + `([^/:?#]*\.)?`)
	case r.flags&fStart != 0:
		b.WriteString("^")
	}
	for _, c := range r.pat {
		switch c {
		case '*':
			b.WriteString(".*")
		case '^':
			// a separator: anything but a letter, a digit or _ - . %
			b.WriteString(`[^a-z0-9_.%-]`)
		case '.', '+', '?', '(', ')', '[', ']', '{', '}', '\\', '$', '|', '/':
			b.WriteByte('\\')
			b.WriteRune(c)
		default:
			if c > 0x7e || c < 0x20 {
				return ""
			}
			b.WriteRune(c)
		}
	}
	if r.flags&fEnd != 0 {
		b.WriteString("$")
	}
	return b.String()
}

func wkStars(ds []string) []string {
	out := make([]string, 0, len(ds))
	for _, d := range ds {
		if d != "" && !strings.ContainsAny(d, "*/") {
			out = append(out, "*"+d)
		}
	}
	return out
}

func wkFromRule(r *rule, action string) (wkRule, bool) {
	f := wkPattern(r)
	if f == "" {
		return wkRule{}, false
	}
	t := wkTrigger{URLFilter: f}
	if action == "block" {
		t.ResourceType = wkKinds(r.kinds)
		if len(t.ResourceType) == 0 {
			return wkRule{}, false
		}
	} else if r.kinds != 0 {
		t.ResourceType = wkKinds(r.kinds)
	}
	switch {
	case r.flags&fThird != 0:
		t.LoadType = []string{"third-party"}
	case r.flags&fFirst != 0:
		t.LoadType = []string{"first-party"}
	}
	if len(r.dom) > 0 {
		t.IfDomain = wkStars(r.dom)
		if len(t.IfDomain) == 0 {
			return wkRule{}, false
		}
	} else if len(r.notDom) > 0 {
		t.UnlessDomain = wkStars(r.notDom)
	}
	return wkRule{Trigger: t, Action: wkAction{Type: action}}, true
}

// ContentRules is the shield as one WebKit content-blocker list (JSON).
// f may be nil (the filter lists not loaded yet).
func ContentRules(f *Engine, set ContentRuleSet) []byte {
	max := set.MaxRules
	if max <= 0 {
		max = 120000
	}
	var blocks, allows []wkRule
	doms := append([]string(nil), set.Domains...)
	sort.Strings(doms)
	for _, d := range doms {
		if len(blocks) >= max*3/4 {
			break
		}
		if d = strings.TrimSpace(strings.ToLower(d)); d != "" && strings.Contains(d, ".") {
			blocks = append(blocks, wkRule{Trigger: wkTrigger{URLFilter: wkHost(d), ResourceType: wkAsked}, Action: wkAction{Type: "block"}})
		}
	}
	if f != nil {
		seen := map[*rule]bool{}
		add := func(rs []*rule, exc bool) {
			for _, r := range rs {
				if seen[r] || len(blocks)+len(allows) >= max {
					continue
				}
				seen[r] = true
				if exc {
					if w, ok := wkFromRule(r, "ignore-previous-rules"); ok {
						allows = append(allows, w)
					}
				} else if w, ok := wkFromRule(r, "block"); ok {
					blocks = append(blocks, w)
				}
			}
		}
		toks := make([]string, 0, len(f.block))
		for t := range f.block {
			toks = append(toks, t)
		}
		sort.Strings(toks)
		for _, t := range toks {
			add(f.block[t], false)
		}
		add(f.blockAny, false)
		toks = toks[:0]
		for t := range f.allow {
			toks = append(toks, t)
		}
		sort.Strings(toks)
		for _, t := range toks {
			add(f.allow[t], true)
		}
		add(f.allowAny, true)
		// whole pages the lists leave alone ($document exceptions)
		for _, r := range f.pageAllow {
			if r.flags&fHost != 0 && !strings.ContainsAny(r.pat, "*/") {
				h := strings.TrimSuffix(r.pat, "^")
				allows = append(allows, wkRule{Trigger: wkTrigger{URLFilter: ".*", IfDomain: []string{"*" + h}}, Action: wkAction{Type: "ignore-previous-rules"}})
			}
		}
	}
	for _, h := range set.Never {
		allows = append(allows, wkRule{Trigger: wkTrigger{URLFilter: wkHost(h)}, Action: wkAction{Type: "ignore-previous-rules"}})
	}
	if off := wkStars(set.Off); len(off) > 0 {
		allows = append(allows, wkRule{Trigger: wkTrigger{URLFilter: ".*", IfDomain: off}, Action: wkAction{Type: "ignore-previous-rules"}})
	}
	all := append(blocks, allows...)
	if len(all) == 0 {
		// WebKit refuses an empty list
		all = append(all, wkRule{Trigger: wkTrigger{URLFilter: `^iris-never-matches:`}, Action: wkAction{Type: "block"}})
	}
	b, _ := json.Marshal(all)
	return b
}
