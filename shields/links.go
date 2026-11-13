package shields

import (
	"net/url"
	"strings"
)

// Links without tracking: the tags that follow you from site to site are
// removed, tracking redirects are skipped, and AMP copies open the original.

var trackingParams = map[string]bool{
	"utm_source": true, "utm_medium": true, "utm_campaign": true, "utm_term": true, "utm_content": true,
	"utm_id": true, "utm_name": true, "utm_reader": true, "utm_social": true, "utm_social-type": true,
	"fbclid": true, "gclid": true, "dclid": true, "gbraid": true, "wbraid": true, "gclsrc": true, "msclkid": true,
	"mc_cid": true, "mc_eid": true, "yclid": true, "igshid": true, "igsh": true, "_hsenc": true, "_hsmi": true,
	"__hssc": true, "__hstc": true, "__hsfp": true, "hsctatracking": true, "oly_anon_id": true, "oly_enc_id": true,
	"vero_id": true, "vero_conv": true, "rb_clickid": true, "s_cid": true, "ml_subscriber": true,
	"ml_subscriber_hash": true, "twclid": true, "ttclid": true, "srsltid": true, "mkt_tok": true, "epik": true,
	"_branch_match_id": true, "_kx": true, "ref_src": true, "ref_url": true, "wickedid": true, "guccounter": true,
	"guce_referrer": true, "guce_referrer_sig": true, "sc_cid": true, "ncid": true, "cmpid": true,
}

// per site, tags that only mean "shared by"
var siteParams = map[string][]string{
	"youtube.com": {"si", "pp", "feature"}, "youtu.be": {"si", "feature"}, "music.youtube.com": {"si"},
	"open.spotify.com": {"si", "context"}, "x.com": {"s", "t"}, "twitter.com": {"s", "t"},
	"instagram.com": {"igsh", "img_index"}, "amazon.com": {"ref_", "pd_rd_r", "pd_rd_w", "pd_rd_wg", "pf_rd_p", "pf_rd_r", "content-id"},
}

// redirectors that carry the real address in a parameter
var redirectors = []struct{ host, path, param string }{
	{"google.", "/url", "q"}, {"google.", "/url", "url"}, {"l.facebook.com", "/l.php", "u"}, {"lm.facebook.com", "/l.php", "u"},
	{"l.instagram.com", "/", "u"}, {"out.reddit.com", "", "url"}, {"www.youtube.com", "/redirect", "q"},
	{"steamcommunity.com", "/linkfilter/", "url"}, {"href.li", "/", ""}, {"go.redirectingat.com", "", "url"},
	{"click.linksynergy.com", "", "murl"}, {"www.awin1.com", "/cread.php", "ued"}, {"t.umblr.com", "/redirect", "z"},
	{"exit.sc", "/", "url"}, {"slack-redir.net", "/link", "url"}, {"vk.com", "/away.php", "to"}, {"away.vk.com", "/away.php", "to"},
	{"duckduckgo.com", "/l/", "uddg"}, {"www.bing.com", "/ck/a", ""},
}

// Clean returns u without tracking (the same address when there is none).
func Clean(raw string) string {
	for i := 0; i < 3; i++ { // redirects can be nested
		next := unwrap(raw)
		if next == raw {
			break
		}
		raw = next
	}
	u, err := url.Parse(raw)
	if err != nil || u.RawQuery == "" || u.Scheme != "http" && u.Scheme != "https" {
		return raw
	}
	host := strings.TrimPrefix(strings.ToLower(u.Hostname()), "www.")
	extra := map[string]bool{}
	for h, ps := range siteParams {
		if host == h || strings.HasSuffix(host, "."+h) {
			for _, p := range ps {
				extra[p] = true
			}
		}
	}
	// keep the query's own order and encoding: drop only the tracking pairs
	parts := strings.Split(u.RawQuery, "&")
	keep := parts[:0]
	changed := false
	for _, p := range parts {
		name, _, _ := strings.Cut(p, "=")
		n, err := url.QueryUnescape(name)
		if err != nil {
			n = name
		}
		n = strings.ToLower(n)
		if trackingParams[n] || extra[n] || strings.HasPrefix(n, "utm_") || strings.HasPrefix(n, "pf_rd_") || strings.HasPrefix(n, "pd_rd_") {
			changed = true
			continue
		}
		keep = append(keep, p)
	}
	if !changed {
		return raw
	}
	u.RawQuery = strings.Join(keep, "&")
	return u.String()
}

// unwrap skips one tracking redirect or AMP copy.
func unwrap(raw string) string {
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" {
		return raw
	}
	host := strings.ToLower(u.Hostname())
	// AMP: google.com/amp/s/site/path and site-com.cdn.ampproject.org/c/s/site/path
	if strings.Contains(host, "google.") && strings.HasPrefix(u.Path, "/amp/s/") {
		return "https://" + strings.TrimPrefix(u.Path, "/amp/s/") + query(u)
	}
	if strings.HasSuffix(host, ".cdn.ampproject.org") {
		p := u.Path
		for _, pre := range []string{"/c/s/", "/v/s/", "/i/s/"} {
			if strings.HasPrefix(p, pre) {
				return "https://" + strings.TrimPrefix(p, pre) + query(u)
			}
		}
	}
	for _, r := range redirectors {
		if !(host == r.host || strings.HasPrefix(r.host, "google.") && strings.Contains(host, "google.") && (strings.HasPrefix(host, "google.") || strings.HasPrefix(host, "www.google."))) {
			continue
		}
		if r.path != "" && !strings.HasPrefix(u.Path, r.path) {
			continue
		}
		if r.param == "" {
			continue
		}
		t := u.Query().Get(r.param)
		if strings.HasPrefix(t, "http://") || strings.HasPrefix(t, "https://") {
			return t
		}
	}
	return raw
}

func query(u *url.URL) string {
	if u.RawQuery == "" {
		return ""
	}
	return "?" + u.RawQuery
}
