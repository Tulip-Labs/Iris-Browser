package core

import (
	"bytes"
	"compress/gzip"
	_ "embed"
	"encoding/json"
	"net/url"
	"regexp"
	"strings"
	"sync"
)

// Lite's blocklist: 100,000+ ad, tracker and malware domains (EasyList,
// EasyPrivacy, uBlock Origin and Brave lists, merged by Lite's build).
//
//go:embed shield-domains.json.gz
var shieldGz []byte

// Shield decides which subresources may load. The list loads lazily in the
// background so startup never waits for it.
type Shield struct {
	once    sync.Once
	ready   chan struct{}
	domains map[string]struct{}
	On      bool
	// Off lists sites (page hosts) where the user turned the shield off.
	Off map[string]bool
	mu  sync.RWMutex
}

func NewShield() *Shield {
	s := &Shield{ready: make(chan struct{}), On: true, Off: map[string]bool{}}
	go s.load()
	return s
}

func (s *Shield) load() {
	s.once.Do(func() {
		defer close(s.ready)
		zr, err := gzip.NewReader(bytes.NewReader(shieldGz))
		if err != nil {
			return
		}
		var list []string
		if json.NewDecoder(zr).Decode(&list) != nil {
			return
		}
		m := make(map[string]struct{}, len(list))
		for _, d := range list {
			if !sharedHosts[d] {
				m[d] = struct{}{}
			}
		}
		s.domains = m
	})
}

// Size is the number of domains in the list (0 while loading).
func (s *Shield) Size() int {
	select {
	case <-s.ready:
		return len(s.domains)
	default:
		return 0
	}
}

// Never blocked: messaging, sign-in and human checks (same list as Lite Desktop).
var neverBlock = []string{"whatsapp.com", "whatsapp.net", "web.whatsapp.com", "accounts.google.com",
	"login.microsoftonline.com", "login.live.com", "teams.microsoft.com", "meet.google.com",
	"challenges.cloudflare.com", "hcaptcha.com", "recaptcha.net", "appleid.apple.com"}

// sharedHosts are hosting and delivery networks that carry the pictures,
// scripts and files of countless ordinary sites. A list that names one of
// them whole would break those sites (courses without pictures, shops
// without photos), so such an entry is dropped; the single ad servers that
// live under them are listed by their full name and stay blocked.
var sharedHosts = map[string]bool{}

func init() {
	for _, d := range []string{"cloudfront.net", "amazonaws.com", "s3.amazonaws.com", "akamaihd.net", "akamaized.net",
		"akamai.net", "edgekey.net", "edgesuite.net", "fastly.net", "fastlylb.net", "azureedge.net", "azurefd.net",
		"azurewebsites.net", "windows.net", "blob.core.windows.net", "msecnd.net", "googleusercontent.com",
		"googleapis.com", "storage.googleapis.com", "gstatic.com", "cloudflare.com", "cloudflare.net", "jsdelivr.net",
		"unpkg.com", "github.io", "githubusercontent.com", "netlify.app", "vercel.app", "herokuapp.com",
		"firebaseapp.com", "web.app", "appspot.com", "b-cdn.net", "cdn77.org", "kxcdn.com", "digitaloceanspaces.com",
		"r2.dev", "pages.dev", "workers.dev", "wp.com", "cloudinary.com", "imgix.net", "ctfassets.net",
		"backblazeb2.com", "rackcdn.com", "llnwd.net", "hwcdn.net", "edgecastcdn.net", "wixstatic.com",
		"squarespace-cdn.com", "shopifycdn.com", "myshopify.com"} {
		sharedHosts[d] = true
	}
}

func under(host, domain string) bool { return host == domain || strings.HasSuffix(host, "."+domain) }

var (
	ytBlockable = regexp.MustCompile(`^/youtubei/v1/(player/ad_break|log_event)\b`)
	ytCritical  = regexp.MustCompile(`^/(youtubei/v1/|watch\b|embed/|s/player/|iframe_api\b|api/timedtext\b|get_video_info\b|shorts/|live/|generate_204\b)`)
	reGoogleTh  = regexp.MustCompile(`^/js/th/`)
)

// YTPlaybackCritical reports requests the YouTube player cannot play without
// (from Lite's ytguard): they always pass, whatever any list says.
func YTPlaybackCritical(u string) bool {
	p, err := url.Parse(u)
	if err != nil {
		return false
	}
	host, path := strings.ToLower(p.Hostname()), p.EscapedPath()
	switch {
	case host == "":
		return false
	case under(host, "googlevideo.com"), under(host, "ytimg.com"), under(host, "ggpht.com"), host == "jnn-pa.googleapis.com":
		return true
	case under(host, "google.com") && reGoogleTh.MatchString(path):
		return true
	case under(host, "youtube.com"), under(host, "youtube-nocookie.com"), host == "youtubei.googleapis.com":
		if ytBlockable.MatchString(path) {
			return false
		}
		return ytCritical.MatchString(path)
	}
	return false
}

// Allow answers for one request made by a page.
// Exempt says whether a request is never blocked: the shield is off (here),
// or it is sign-in, messaging, a human check or YouTube playback.
func (s *Shield) Exempt(reqURL, pageURL string) bool {
	if !s.On {
		return true
	}
	s.mu.RLock()
	off := s.Off[Host(pageURL)]
	s.mu.RUnlock()
	if off {
		return true
	}
	host := Host(reqURL)
	if host == "" {
		return true
	}
	for _, d := range neverBlock {
		if under(host, d) {
			return true
		}
	}
	return YTPlaybackCritical(reqURL)
}

func (s *Shield) Allow(reqURL, pageURL string) bool {
	if !s.On {
		return true
	}
	page := Host(pageURL)
	s.mu.RLock()
	off := s.Off[page]
	s.mu.RUnlock()
	if off {
		return true
	}
	host := Host(reqURL)
	if host == "" {
		return true
	}
	for _, d := range neverBlock {
		if under(host, d) {
			return true
		}
	}
	if YTPlaybackCritical(reqURL) {
		return true
	}
	if p, err := url.Parse(reqURL); err == nil && (under(host, "youtube.com") && ytBlockable.MatchString(p.EscapedPath())) {
		return false
	}
	select {
	case <-s.ready:
	default:
		return true // list still loading: never hold a request
	}
	// the host and each parent domain, but never a bare public suffix like "com"
	for h := host; strings.Contains(h, "."); {
		if _, bad := s.domains[h]; bad {
			return false
		}
		i := strings.IndexByte(h, '.')
		h = h[i+1:]
	}
	return true
}

// SetSiteOff turns the shield off (or back on) for one site.
func (s *Shield) SetSiteOff(host string, off bool) {
	s.mu.Lock()
	if off {
		s.Off[host] = true
	} else {
		delete(s.Off, host)
	}
	s.mu.Unlock()
}

// Wait blocks until the list is loaded (tests).
func (s *Shield) Wait() { <-s.ready }

// Domains returns up to n blocked domains (for engines that take a whole list).
func (s *Shield) Domains(n int) []string {
	select {
	case <-s.ready:
	default:
		return nil
	}
	out := make([]string, 0, min(n, len(s.domains)))
	for d := range s.domains {
		if len(out) >= n {
			break
		}
		out = append(out, d)
	}
	return out
}
