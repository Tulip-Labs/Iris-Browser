package shields

import (
	"sort"
	"strings"
)

// Hiding rules: CSS selectors for what ads leave behind. Rules for a site are
// filed under its domain; generic ones under the class or id they need, so a
// page only gets the ones that can match it (Brave does the same), plus a short
// list of generic rules with no class or id.

type cosmetic struct {
	site       map[string][]string // domain (or name.*) -> selectors
	siteExcept map[string][]string
	byClass    map[string][]string
	byID       map[string][]string
	always     []string
	except     map[string]bool // generic exceptions (#@#sel)
}

func newCosmetic() cosmetic {
	return cosmetic{site: map[string][]string{}, siteExcept: map[string][]string{},
		byClass: map[string][]string{}, byID: map[string][]string{}, except: map[string]bool{}}
}

// procedural selectors (uBlock's own extensions) that a style sheet cannot use
var procedural = []string{":has-text(", ":upward(", ":xpath(", ":matches-css", ":-abp-", ":style(", ":remove(",
	":min-text-length(", ":watch-attr(", ":matches-path(", ":matches-attr(", ":matches-prop(", ":others(", ":shadow(", "+js(", ":contains("}

func (c *cosmetic) add(line string, i int) bool {
	domains := line[:i]
	rest := line[i:]
	exc := false
	switch {
	case strings.HasPrefix(rest, "##"):
		rest = rest[2:]
	case strings.HasPrefix(rest, "#@#"):
		rest, exc = rest[3:], true
	default:
		return false // #?#, #$#, #%#: procedural, CSS injection or scripts
	}
	sel := strings.TrimSpace(rest)
	if sel == "" || strings.HasPrefix(sel, "+js") || strings.HasPrefix(sel, "^") || strings.ContainsAny(sel, "{}") {
		return false
	}
	for _, p := range procedural {
		if strings.Contains(sel, p) {
			return false
		}
	}
	if domains == "" {
		if exc {
			c.except[sel] = true
			return true
		}
		if k, isID := key(sel); k != "" {
			if isID {
				c.byID[k] = append(c.byID[k], sel)
			} else {
				c.byClass[k] = append(c.byClass[k], sel)
			}
		} else if len(c.always) < 3000 {
			c.always = append(c.always, sel)
		} else {
			return false
		}
		return true
	}
	for _, d := range strings.Split(domains, ",") {
		d = strings.ToLower(strings.TrimSpace(d))
		if d == "" || strings.HasPrefix(d, "~") {
			continue // a negated site: rare, and safer to skip
		}
		if exc {
			c.siteExcept[d] = append(c.siteExcept[d], sel)
		} else {
			c.site[d] = append(c.site[d], sel)
		}
	}
	return true
}

// key finds the class or id a generic selector starts with (.ad, #banner,
// div.sponsor...), when it has one.
func key(sel string) (string, bool) {
	j := 0
	for j < len(sel) && (sel[j] >= 'a' && sel[j] <= 'z' || sel[j] >= 'A' && sel[j] <= 'Z' || sel[j] >= '0' && sel[j] <= '9') {
		j++ // a tag name
	}
	if j >= len(sel) || sel[j] != '.' && sel[j] != '#' {
		return "", false
	}
	isID := sel[j] == '#'
	k := j + 1
	for k < len(sel) && (isWordByte(sel[k]) || sel[k] == '-' || sel[k] == '_') {
		k++
	}
	if k == j+1 {
		return "", false
	}
	return sel[j+1 : k], isID
}

// siteKeys are the names a page's hiding rules can be filed under.
func siteKeys(host string) []string {
	var out []string
	for h := host; h != ""; {
		out = append(out, h)
		i := strings.IndexByte(h, '.')
		if i < 0 {
			break
		}
		h = h[i+1:]
	}
	s := site(host)
	name, _, _ := strings.Cut(s, ".")
	h := strings.TrimSuffix(host, s) + name
	for h != "" {
		out = append(out, h+".*")
		i := strings.IndexByte(h, '.')
		if i < 0 {
			break
		}
		h = h[i+1:]
	}
	return out
}

// SiteSelectors are the hiding rules for a page (its site's, and the generic
// ones with no class or id), applied as soon as the page starts.
func (e *Engine) SiteSelectors(page string) []string {
	if e == nil {
		return nil
	}
	host := pageHost(page)
	ex := map[string]bool{}
	var out []string
	for _, k := range siteKeys(host) {
		for _, s := range e.cos.siteExcept[k] {
			ex[s] = true
		}
	}
	for _, k := range siteKeys(host) {
		for _, s := range e.cos.site[k] {
			if !ex[s] {
				out = append(out, s)
			}
		}
	}
	if !e.genericHidden(page) {
		for _, s := range e.cos.always {
			if !ex[s] && !e.cos.except[s] {
				out = append(out, s)
			}
		}
	}
	return out
}

// GenericSelectors are the generic rules that can match a page with these
// classes and ids (Iris reads them from the page once it has loaded).
func (e *Engine) GenericSelectors(page string, classes, ids []string) []string {
	if e == nil || e.genericHidden(page) {
		return nil
	}
	ex := map[string]bool{}
	for _, k := range siteKeys(pageHost(page)) {
		for _, s := range e.cos.siteExcept[k] {
			ex[s] = true
		}
	}
	seen := map[string]bool{}
	var out []string
	add := func(list []string) {
		for _, s := range list {
			if !seen[s] && !ex[s] && !e.cos.except[s] {
				seen[s] = true
				out = append(out, s)
			}
		}
	}
	for _, c := range classes {
		add(e.cos.byClass[c])
	}
	for _, i := range ids {
		add(e.cos.byID[i])
	}
	sort.Strings(out)
	return out
}

func (e *Engine) genericHidden(page string) bool {
	for _, p := range e.genericOff {
		if e.matchPage(p, page) {
			return true
		}
	}
	return false
}

// HideCSS turns selectors into a style sheet: one rule per selector, so one
// that this engine does not understand cannot cancel the others.
func HideCSS(sels []string) string {
	var b strings.Builder
	for _, s := range sels {
		b.WriteString(s)
		b.WriteString("{display:none!important}\n")
	}
	return b.String()
}
