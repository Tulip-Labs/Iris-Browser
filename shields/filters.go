// Package shields is Iris's version of what Brave calls Shields: an ad and
// tracker blocker that reads the same filter lists (EasyList, EasyPrivacy,
// uBlock filters, the cookie notice list), hiding of the boxes ads leave
// behind, links cleaned of tracking, and fingerprinting protection.
//
// The network matcher follows the usual design (Brave's adblock-rust and
// uBlock Origin work the same way): every rule is filed under its rarest
// whole word, and a request only checks the rules filed under the words of its
// own address, so a page's hundreds of requests cost microseconds each.
package shields

import (
	"bufio"
	"io"
	"regexp"
	"strings"
	"sync"

	"golang.org/x/net/publicsuffix"
)

// Kind is what a request loads, in filter list terms.
type Kind uint16

const (
	KindScript Kind = 1 << iota
	KindImage
	KindStylesheet
	KindXHR
	KindMedia
	KindFont
	KindSubdocument
	KindPing
	KindOther
	KindDocument
	kindAll = 1<<10 - 1
)

// the kinds Iris asks about (style sheets and fonts are never blocked)
const askedKinds = KindScript | KindImage | KindXHR | KindMedia | KindPing | KindOther

var kindNames = map[string]Kind{
	"script": KindScript, "image": KindImage, "stylesheet": KindStylesheet, "css": KindStylesheet,
	"xmlhttprequest": KindXHR, "xhr": KindXHR, "media": KindMedia, "font": KindFont,
	"subdocument": KindSubdocument, "frame": KindSubdocument, "ping": KindPing, "beacon": KindPing,
	"other": KindOther, "object": KindOther, "websocket": KindXHR, "webrtc": KindOther,
	"document": KindDocument, "doc": KindDocument, "all": kindAll,
}

const (
	fHost      = 1 << iota // ||: starts at a label of the host
	fStart                 // |: starts the address
	fEnd                   // ends the address
	fException             // @@
	fImportant
	fThird
	fFirst
	fCase
	fRegex
)

type rule struct {
	pat    string
	flags  uint16
	kinds  Kind // 0 = any
	tokOff int  // where the filed word sits in pat; -1 when a * comes before it
	dom    []string
	notDom []string
	re     *regexp.Regexp
}

// Engine matches requests and finds the hiding rules for a page.
type Engine struct {
	block, allow map[string][]*rule // by word
	blockAny     []*rule            // rules with no usable word
	allowAny     []*rule
	pageAllow    []*rule // @@...$document: the shield is off on these pages
	genericOff   []*rule // @@...$generichide / $elemhide
	cos          cosmetic
	Rules        int // network rules kept
	Hiding       int // hiding rules kept

	mu       sync.Mutex
	lastPage string // the page-level exceptions are judged once per page
	pageOff  bool
}

// New makes an empty engine; add lists with Add.
func New() *Engine {
	return &Engine{block: map[string][]*rule{}, allow: map[string][]*rule{}, cos: newCosmetic()}
}

// Add reads a filter list.
func (e *Engine) Add(r io.Reader) {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 64<<10), 1<<20)
	for sc.Scan() {
		e.AddLine(sc.Text())
	}
}

// AddLine reads one filter.
func (e *Engine) AddLine(line string) {
	line = strings.TrimSpace(line)
	if line == "" || line[0] == '!' || line[0] == '[' {
		return
	}
	if i := cosmeticSep(line); i >= 0 {
		if e.cos.add(line, i) {
			e.Hiding++
		}
		return
	}
	r, kind := parseNetwork(line)
	if r == nil {
		return
	}
	_, r.tokOff = bestToken(r)
	if r.pat == "" {
		r.tokOff = -1
	}
	switch kind {
	case "page":
		e.pageAllow = append(e.pageAllow, r)
		return
	case "generichide":
		e.genericOff = append(e.genericOff, r)
		return
	}
	e.Rules++
	tok, off := bestToken(r)
	r.tokOff = off
	exc := r.flags&fException != 0
	switch {
	case tok == "" && exc:
		e.allowAny = append(e.allowAny, r)
	case tok == "":
		e.blockAny = append(e.blockAny, r)
	case exc:
		e.allow[tok] = append(e.allow[tok], r)
	default:
		e.block[tok] = append(e.block[tok], r)
	}
}

// cosmeticSep finds the ## / #@# that makes a line a hiding rule.
func cosmeticSep(line string) int {
	for i := 0; i+1 < len(line); i++ {
		if line[i] != '#' {
			continue
		}
		switch {
		case line[i+1] == '#', line[i+1] == '@' && i+2 < len(line) && line[i+2] == '#',
			line[i+1] == '?' || line[i+1] == '$' || line[i+1] == '%':
			return i
		}
	}
	return -1
}

var unsupportedOpt = map[string]bool{
	"csp": true, "removeparam": true, "redirect-rule": true, "replace": true, "rewrite": true, "popup": true,
	"popunder": true, "header": true, "permissions": true, "urlskip": true, "uritransform": true, "urltransform": true,
	"jsonprune": true, "denyallow": true, "to": true, "badfilter": true, "cname": true, "inline-script": true,
	"inline-font": true, "mp4": true, "empty": false, "genericblock": true, "specifichide": true, "shide": true,
	"method": true, "ipaddress": true, "strict1p": true, "strict3p": true, "strict-first-party": true,
	"strict-third-party": true, "responseheader": true, "trusted-urlskip": true,
}

// parseNetwork reads a request rule; kind is "page" or "generichide" for the
// exceptions that switch the shield or the generic hiding off on a page.
func parseNetwork(line string) (*rule, string) {
	r := &rule{}
	if strings.HasPrefix(line, "@@") {
		r.flags |= fException
		line = line[2:]
	}
	pat, opts := line, ""
	isRegex := false
	if strings.HasPrefix(pat, "/") && len(pat) > 2 {
		// a regex rule ends with a slash, or a slash and its options
		if strings.HasSuffix(pat, "/") {
			isRegex = true
		} else if j := strings.LastIndex(pat, "/$"); j > 0 && !strings.ContainsAny(pat[j+2:], "/\\") {
			pat, opts, isRegex = pat[:j+1], pat[j+2:], true
		}
	}
	if isRegex {
		// options already split off
	} else if j := strings.LastIndexByte(pat, '$'); j >= 0 && !strings.Contains(pat[j:], "/") {
		pat, opts = pat[:j], pat[j+1:]
	}
	special := ""
	if opts != "" {
		for _, o := range strings.Split(opts, ",") {
			neg := strings.HasPrefix(o, "~")
			o = strings.TrimPrefix(o, "~")
			name, val, _ := strings.Cut(o, "=")
			name = strings.ToLower(name)
			switch {
			case unsupportedOpt[name]:
				return nil, ""
			case name == "third-party" || name == "3p":
				r.flags |= map[bool]uint16{false: fThird, true: fFirst}[neg]
			case name == "first-party" || name == "1p":
				r.flags |= map[bool]uint16{false: fFirst, true: fThird}[neg]
			case name == "important":
				r.flags |= fImportant
			case name == "match-case":
				r.flags |= fCase
			case name == "domain" || name == "from":
				for _, d := range strings.Split(val, "|") {
					if strings.HasPrefix(d, "~") {
						r.notDom = append(r.notDom, strings.ToLower(d[1:]))
					} else if d != "" {
						r.dom = append(r.dom, strings.ToLower(d))
					}
				}
			case name == "redirect":
				// blocking is what matters here
			case name == "generichide" || name == "ghide" || name == "elemhide" || name == "ehide":
				special = "generichide"
			case kindNames[name] != 0:
				k := kindNames[name]
				if k == KindDocument && !neg {
					special = "page"
					continue
				}
				if neg {
					if r.kinds == 0 {
						r.kinds = kindAll
					}
					r.kinds &^= k
				} else {
					r.kinds |= k
				}
			default:
				return nil, "" // an option we do not know: safer to skip the rule
			}
		}
	}
	if special != "" && r.flags&fException == 0 {
		return nil, ""
	}
	if special == "" && r.kinds != 0 && r.kinds&askedKinds == 0 {
		return nil, "" // only for things Iris never blocks
	}
	if isRegex {
		re, err := regexp.Compile(pat[1 : len(pat)-1])
		if err != nil {
			return nil, ""
		}
		r.re, r.flags = re, r.flags|fRegex
		return r, special
	}
	switch {
	case strings.HasPrefix(pat, "||"):
		r.flags |= fHost
		pat = pat[2:]
	case strings.HasPrefix(pat, "|"):
		r.flags |= fStart
		pat = pat[1:]
	}
	if strings.HasSuffix(pat, "|") {
		r.flags |= fEnd
		pat = pat[:len(pat)-1]
	}
	pat = strings.Trim(pat, "*")
	if r.flags&fHost != 0 {
		pat = strings.TrimPrefix(pat, "*")
	}
	if pat == "" && special == "" {
		return nil, "" // matches everything: never useful here
	}
	if r.flags&fCase == 0 {
		pat = strings.ToLower(pat)
	}
	r.pat = pat
	return r, special
}

func isWordByte(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c >= 'A' && c <= 'Z' || c == '%'
}

var commonWords = map[string]bool{"http": true, "https": true, "www": true, "com": true, "js": true, "net": true, "org": true, "html": true, "php": true}

// bestToken picks the longest whole word of the pattern (one that cannot be
// part of a longer word in a matching address) and where it sits.
func bestToken(r *rule) (string, int) {
	if r.flags&fRegex != 0 {
		return "", -1
	}
	p := r.pat
	best, off := "", -1
	star := false
	for i := 0; i < len(p); {
		if p[i] == '*' {
			star = true
		}
		if !isWordByte(p[i]) {
			i++
			continue
		}
		j := i
		for j < len(p) && isWordByte(p[j]) {
			j++
		}
		w := p[i:j]
		leftOK := i > 0 && p[i-1] != '*' || i == 0 && r.flags&(fHost|fStart) != 0
		rightOK := j < len(p) && p[j] != '*' || j == len(p) && r.flags&fEnd != 0
		if leftOK && rightOK && len(w) >= 2 && !commonWords[w] && len(w) > len(best) {
			best = strings.ToLower(w)
			off = i
			if star {
				off = -1
			}
		}
		i = j
	}
	return best, off
}

// Request is one subresource to judge.
type Request struct {
	URL, Page string
	Kind      Kind
}

type req struct {
	url, lower         string
	hostStart, hostEnd int
	host, page         string
	third              bool
	kind               Kind
}

func prepare(q Request) req {
	r := req{url: q.URL, lower: strings.ToLower(q.URL), kind: q.Kind}
	if i := strings.Index(r.lower, "://"); i >= 0 {
		r.hostStart = i + 3
	}
	r.hostEnd = len(r.lower)
	for k := r.hostStart; k < len(r.lower); k++ {
		if c := r.lower[k]; c == '/' || c == ':' || c == '?' || c == '#' {
			r.hostEnd = k
			break
		}
	}
	r.host = r.lower[r.hostStart:r.hostEnd]
	r.page = pageHost(q.Page)
	r.third = r.page != "" && site(r.host) != site(r.page)
	return r
}

func pageHost(u string) string {
	u = strings.ToLower(u)
	if i := strings.Index(u, "://"); i >= 0 {
		u = u[i+3:]
	}
	for k := 0; k < len(u); k++ {
		if c := u[k]; c == '/' || c == ':' || c == '?' || c == '#' {
			return u[:k]
		}
	}
	return u
}

// site is the registrable domain (example.co.uk for a.b.example.co.uk).
func site(host string) string {
	if s, err := publicsuffix.EffectiveTLDPlusOne(host); err == nil {
		return s
	}
	return host
}

// Blocked says whether the request should not load.
func (e *Engine) Blocked(q Request) bool {
	if e == nil {
		return false
	}
	if e.shieldOffOn(q.Page) {
		return false
	}
	r := prepare(q)
	hit := e.find(e.block, e.blockAny, &r)
	if hit == nil {
		return false
	}
	if hit.flags&fImportant != 0 {
		return true
	}
	return e.find(e.allow, e.allowAny, &r) == nil
}

// Excepted says whether an exception rule lets the request through (it lifts
// blocks from other sources too, like the built-in domain list).
func (e *Engine) Excepted(q Request) bool {
	if e == nil {
		return false
	}
	r := prepare(q)
	return e.find(e.allow, e.allowAny, &r) != nil
}

// shieldOffOn says whether a list switches blocking off on the page.
func (e *Engine) shieldOffOn(page string) bool {
	e.mu.Lock()
	defer e.mu.Unlock()
	if page != e.lastPage {
		e.lastPage, e.pageOff = page, false
		for _, p := range e.pageAllow {
			if e.matchPage(p, page) {
				e.pageOff = true
				break
			}
		}
	}
	return e.pageOff
}

func (e *Engine) matchPage(p *rule, page string) bool {
	if page == "" {
		return false
	}
	r := prepare(Request{URL: page, Page: page, Kind: KindDocument})
	return e.matches(p, &r, true)
}

func (e *Engine) find(idx map[string][]*rule, any []*rule, r *req) *rule {
	s := r.lower
	for i := 0; i < len(s); {
		if !isWordByte(s[i]) {
			i++
			continue
		}
		j := i
		for j < len(s) && isWordByte(s[j]) {
			j++
		}
		for _, rl := range idx[s[i:j]] {
			if e.matches(rl, r, false) {
				return rl
			}
		}
		i = j
	}
	for _, rl := range any {
		if e.matches(rl, r, false) {
			return rl
		}
	}
	return nil
}

func (e *Engine) matches(rl *rule, r *req, pageRule bool) bool {
	if !pageRule {
		if rl.kinds != 0 && rl.kinds&r.kind == 0 {
			return false
		}
		if rl.flags&fThird != 0 && !r.third || rl.flags&fFirst != 0 && r.third {
			return false
		}
	}
	if len(rl.dom) > 0 || len(rl.notDom) > 0 {
		if !domainOK(r.page, rl.dom, rl.notDom) {
			return false
		}
	}
	s := r.lower
	if rl.flags&fCase != 0 {
		s = r.url
	}
	if rl.re != nil {
		return rl.re.MatchString(s)
	}
	end := rl.flags&fEnd != 0
	try := func(start int) bool {
		if start < 0 || start > len(s) {
			return false
		}
		if rl.flags&fStart != 0 && start != 0 {
			return false
		}
		if rl.flags&fHost != 0 && !(start >= r.hostStart && start < r.hostEnd && (start == r.hostStart || s[start-1] == '.')) {
			return false
		}
		return glob(rl.pat, s[start:], end)
	}
	switch {
	case rl.flags&fStart != 0:
		return try(0)
	case rl.flags&fHost != 0:
		for k := r.hostStart; k < r.hostEnd; k++ {
			if (k == r.hostStart || s[k-1] == '.') && try(k) {
				return true
			}
		}
		return false
	case rl.tokOff >= 0 && rl.tokOff < len(rl.pat):
		// start where the filed word appears
		tok := rl.pat[rl.tokOff:]
		n := 0
		for n < len(tok) && isWordByte(tok[n]) {
			n++
		}
		tok = tok[:n]
		for from := 0; ; {
			k := strings.Index(s[from:], tok)
			if k < 0 {
				return false
			}
			if try(from + k - rl.tokOff) {
				return true
			}
			from += k + 1
		}
	}
	for k := 0; k <= len(s); k++ {
		if try(k) {
			return true
		}
	}
	return false
}

func domainOK(page string, dom, notDom []string) bool {
	for _, d := range notDom {
		if hostIs(page, d) {
			return false
		}
	}
	if len(dom) == 0 {
		return true
	}
	for _, d := range dom {
		if hostIs(page, d) {
			return true
		}
	}
	return false
}

// hostIs says whether host is d or under it (d may end in .* for any TLD).
func hostIs(host, d string) bool {
	if strings.HasSuffix(d, ".*") {
		// google.* matches google.com, google.com.co, www.google.de...
		s := site(host)
		name, _, _ := strings.Cut(s, ".")
		h := strings.TrimSuffix(host, s) + name
		base := d[:len(d)-2]
		return h == base || strings.HasSuffix(h, "."+base)
	}
	return host == d || strings.HasSuffix(host, "."+d)
}

func isSep(c byte) bool {
	return !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '-' || c == '.' || c == '%')
}

// glob matches pattern p (with * and the ^ separator) against the start of s,
// or all of s when end is set.
func glob(p, s string, end bool) bool {
	pi, si, star, mark := 0, 0, -1, 0
	for {
		if pi == len(p) {
			if !end || si == len(s) {
				return true
			}
		} else {
			c := p[pi]
			switch {
			case c == '*':
				star, mark = pi, si
				pi++
				continue
			case si < len(s) && (c == s[si] || c == '^' && isSep(s[si])):
				pi++
				si++
				continue
			case c == '^' && si == len(s):
				pi++
				continue
			}
		}
		if star < 0 {
			return false
		}
		mark++
		if mark > len(s) {
			return false
		}
		pi, si = star+1, mark
	}
}
