package core

import (
	"regexp"
	"sort"
	"strings"
)

// Lite results ranks links like a careful reader would: references, official
// sites, documentation, research and real discussions rise; shops, coupon and
// download farms, content mills and listicles built for ads sink or go; one
// site never fills the page. The user's own raise, lower and hide choices win.

// Quality is how Lite Go judged a link.
type Quality struct {
	Score float64
	Label string // a short kind shown on the result ("Reference", "Docs"...); "" when ordinary
}

type tier struct {
	weight float64
	label  string
}

var siteTiers = map[string]tier{}

func addTier(w float64, label string, hosts ...string) {
	for _, h := range hosts {
		siteTiers[h] = tier{w, label}
	}
}

func init() {
	addTier(1.7, "Reference", "wikipedia.org", "britannica.com", "wiktionary.org", "wikivoyage.org", "merriam-webster.com", "dictionary.cambridge.org", "oxfordreference.com", "plato.stanford.edu", "khanacademy.org")
	addTier(1.6, "Docs", "developer.mozilla.org", "go.dev", "pkg.go.dev", "docs.python.org", "learn.microsoft.com", "developer.android.com", "developer.apple.com", "docs.oracle.com", "kotlinlang.org", "rust-lang.org", "doc.rust-lang.org", "cppreference.com", "postgresql.org", "sqlite.org", "kubernetes.io", "docs.docker.com", "nodejs.org", "react.dev", "gioui.org", "man7.org", "w3.org", "whatwg.org", "ietf.org", "rfc-editor.org")
	addTier(1.55, "Research", "arxiv.org", "nature.com", "science.org", "ncbi.nlm.nih.gov", "pubmed.ncbi.nlm.nih.gov", "scholar.google.com", "jstor.org", "sciencedirect.com", "springer.com", "acm.org", "ieee.org", "nejm.org", "thelancet.com", "cochranelibrary.com", "who.int", "cdc.gov", "nih.gov", "mayoclinic.org", "clevelandclinic.org", "nasa.gov", "noaa.gov")
	addTier(1.35, "Discussion", "stackoverflow.com", "stackexchange.com", "superuser.com", "serverfault.com", "askubuntu.com", "reddit.com", "news.ycombinator.com", "lobste.rs", "github.com", "gitlab.com", "discourse.org")
	addTier(1.3, "News", "reuters.com", "apnews.com", "bbc.com", "bbc.co.uk", "npr.org", "theguardian.com", "nytimes.com", "washingtonpost.com", "economist.com", "ft.com", "bloomberg.com", "aljazeera.com", "elpais.com", "eltiempo.com", "lemonde.fr", "dw.com", "arstechnica.com", "theverge.com", "wired.com", "nationalgeographic.com", "smithsonianmag.com")
	addTier(1.2, "", "youtube.com", "imdb.com", "letterboxd.com", "goodreads.com", "openstreetmap.org", "archive.org", "gutenberg.org", "worldwildlife.org", "si.edu")
	// shops: lowered unless the search is about buying
	addTier(0.5, "Shop", "amazon.com", "ebay.com", "aliexpress.com", "temu.com", "walmart.com", "etsy.com", "bestbuy.com", "target.com", "shein.com", "mercadolibre.com", "mercadolibre.com.co", "falabella.com", "alibaba.com", "wish.com")
	// coupon, download and content farms
	addTier(0.3, "", "retailmenot.com", "groupon.com", "couponfollow.com", "dealspotr.com", "knoji.com", "softonic.com", "filehippo.com", "uptodown.com", "malavida.com", "ehow.com", "answers.com", "reference.com", "ask.com", "wikihow.com", "brainly.com", "coursehero.com", "chegg.com", "scribd.com", "slideshare.net", "pinterest.com", "pinterest.co.uk", "quora.com", "msn.com", "yahoo.com", "linkedin.com", "facebook.com", "instagram.com", "tiktok.com")
}

var (
	buyIntent = regexp.MustCompile(`(?i)\b(buy|price|prices|cheap|cheapest|deal|deals|discount|coupon|shop|store|order|sale|cost|comprar|precio|tienda)\b`)
	adTitle   = regexp.MustCompile(`(?i)\b(coupon|promo code|% off|discount code|sponsored|best .{2,40} (of )?20\d\d|top \d+ best|\d+ best .{2,30} to buy|free download|crack|apk mod|limited time|sale ends)\b`)
)

func siteTier(host string) (tier, bool) {
	h := strings.TrimPrefix(strings.ToLower(host), "www.")
	for h != "" {
		if t, ok := siteTiers[h]; ok {
			return t, true
		}
		i := strings.IndexByte(h, '.')
		if i < 0 {
			break
		}
		h = h[i+1:]
	}
	switch {
	case strings.HasSuffix(h, ".gov") || strings.Contains(host, ".gov."):
		return tier{1.6, "Official"}, true
	case strings.HasSuffix(h, ".edu") || strings.Contains(host, ".edu."):
		return tier{1.5, "Academic"}, true
	case strings.HasSuffix(h, ".int"):
		return tier{1.5, "Official"}, true
	}
	return tier{1, ""}, false
}

// Judge rates one link at position i of Google's order.
func Judge(r WebResult, i int, query string, ranks map[string]int) Quality {
	host := strings.TrimPrefix(Host(r.URL), "www.")
	t, _ := siteTier(host)
	w := t.weight
	if t.label == "Shop" && buyIntent.MatchString(query) {
		w = 1.1
	}
	if adTitle.MatchString(r.Title) && !adTitle.MatchString(query) {
		w *= 0.55
	}
	switch ranks[siteKey(host)] {
	case 1:
		w *= 2.2
	case -1:
		w *= 0.35
	case -2:
		w = 0
	}
	return Quality{Score: w / (1 + float64(i)*0.32), Label: t.label}
}

// siteKey is the part of a host that the user's choices apply to.
func siteKey(host string) string {
	h := strings.TrimPrefix(strings.ToLower(host), "www.")
	parts := strings.Split(h, ".")
	if len(parts) > 2 {
		// keep three parts for country second levels (bbc.co.uk), two otherwise
		if len(parts[len(parts)-2]) <= 3 && len(parts[len(parts)-1]) == 2 {
			return strings.Join(parts[len(parts)-3:], ".")
		}
		return strings.Join(parts[len(parts)-2:], ".")
	}
	return h
}

// SiteKey is siteKey for callers outside.
func SiteKey(u string) string { return siteKey(Host(u)) }

// Ranked is a link with its judgement.
type Ranked struct {
	WebResult
	Quality
}

// Rank orders links by quality, drops hidden sites and links that are pure
// promotion, and keeps at most two per site.
func Rank(in []WebResult, query string, ranks map[string]int) []Ranked {
	var out []Ranked
	for i, r := range in {
		q := Judge(r, i, query, ranks)
		if q.Score <= 0.06 {
			continue
		}
		out = append(out, Ranked{r, q})
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Score > out[j].Score })
	per := map[string]int{}
	keep := out[:0]
	for _, r := range out {
		k := siteKey(Host(r.URL))
		if per[k] >= 2 {
			continue
		}
		per[k]++
		keep = append(keep, r)
	}
	return keep
}

// Host is the link's host.
func (r Ranked) Host() string { return Host(r.URL) }
