// Package route decides which engine draws a page: WebKitGTK for most pages
// (articles, Wikipedia, search, docs), the heavy engine (Electron) for the
// sites that need it and for any site WebKit failed on. See docs/engines.md.
package route

import (
	"encoding/json"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"iris/core/safefile"
)

// Engine is which engine draws a page.
type Engine int

const (
	Light Engine = iota // WebKit
	Heavy               // Electron (Chromium with H.264, H.265 and AAC)
)

func (e Engine) String() string {
	if e == Heavy {
		return "heavy"
	}
	return "light"
}

// heavySites are drawn by the heavy engine with all their subdomains:
// video, social sites and web apps, which need what only Electron has today.
var heavySites = []string{
	// video and media
	"youtube.com", "youtu.be", "youtube-nocookie.com", "netflix.com", "twitch.tv",
	"vimeo.com", "spotify.com", "primevideo.com", "disneyplus.com", "hulu.com",
	// social
	"linkedin.com", "facebook.com", "instagram.com", "x.com", "twitter.com",
	"tiktok.com", "reddit.com", "threads.net", "whatsapp.com", "messenger.com",
	// web apps
	"docs.google.com", "mail.google.com", "drive.google.com", "meet.google.com",
	"calendar.google.com", "outlook.com", "outlook.live.com", "office.com",
	"teams.microsoft.com", "figma.com", "discord.com", "slack.com", "notion.so",
	"canva.com", "web.telegram.org",
	// sign-in pages: they set the cookies both engines share, and check the
	// browser closely
	"accounts.google.com", "login.microsoftonline.com", "login.live.com",
	"appleid.apple.com", "github.com/login",
}

// Router keeps the reader's choices and the sites WebKit failed on, in
// routes.json in its folder.
type Router struct {
	mu   sync.Mutex
	path string
	st   state
	// Extra heavy host names (tests, and IRIS_HEAVY_HOSTS for diagnosis).
	Extra []string
	now   func() time.Time
}

type state struct {
	// Choice is the reader's: a site always drawn by one engine.
	Choice map[string]Engine `json:"choice,omitempty"`
	// Failed are sites WebKit could not draw, and when (they are tried in
	// WebKit again after a month: WebKit improves with each release).
	Failed map[string]int64 `json:"failed,omitempty"`
}

const retryAfter = 30 * 24 * time.Hour

// Open reads the router's file in dir ("" keeps it in memory only).
func Open(dir string) *Router {
	r := &Router{now: time.Now}
	if dir != "" {
		r.path = filepath.Join(dir, "routes.json")
		if b, err := os.ReadFile(r.path); err == nil {
			json.Unmarshal(b, &r.st)
		}
	}
	if extra := os.Getenv("IRIS_HEAVY_HOSTS"); extra != "" {
		r.Extra = strings.Fields(strings.ReplaceAll(extra, ",", " "))
	}
	return r
}

// site is the host of an address, without "www.", or "" when it has none.
func site(u string) (host, path string) {
	p, err := url.Parse(u)
	if err != nil {
		return "", ""
	}
	return strings.TrimPrefix(strings.ToLower(p.Hostname()), "www."), p.Path
}

// under says whether host is domain or one of its subdomains.
func under(host, domain string) bool {
	return host == domain || strings.HasSuffix(host, "."+domain)
}

// Pick says which engine should draw the page at address u.
func (r *Router) Pick(u string) Engine {
	low := strings.ToLower(u)
	switch {
	case u == "" || strings.HasPrefix(low, "about:") || strings.HasPrefix(low, "data:"):
		return Light
	case !strings.HasPrefix(low, "http://") && !strings.HasPrefix(low, "https://"):
		return Heavy // file pickers' files, view-source, extension pages
	}
	host, path := site(u)
	if host == "" {
		return Heavy
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	// the reader's choice wins, for the site or the domain it is under
	for h, e := range r.st.Choice {
		if under(host, h) {
			return e
		}
	}
	for _, h := range r.Extra {
		if under(host, h) {
			return Heavy
		}
	}
	for _, s := range heavySites {
		d, p, _ := strings.Cut(s, "/")
		if under(host, d) && (p == "" || strings.HasPrefix(strings.TrimPrefix(path, "/"), p)) {
			return Heavy
		}
	}
	if at, ok := r.st.Failed[host]; ok {
		if r.now().Sub(time.Unix(at, 0)) < retryAfter {
			return Heavy
		}
	}
	return Light
}

// Failed remembers that WebKit could not draw the site of u (it crashed or
// drew nothing): it goes to the heavy engine from now on, for a month.
func (r *Router) Failed(u string) {
	host, _ := site(u)
	if host == "" {
		return
	}
	r.mu.Lock()
	if r.st.Failed == nil {
		r.st.Failed = map[string]int64{}
	}
	r.st.Failed[host] = r.now().Unix()
	r.mu.Unlock()
	r.save()
}

// Choose makes the site of u always open in engine e (the three dots menu's
// "Open in full engine" and its way back).
func (r *Router) Choose(u string, e Engine) {
	host, _ := site(u)
	if host == "" {
		return
	}
	r.mu.Lock()
	if r.st.Choice == nil {
		r.st.Choice = map[string]Engine{}
	}
	r.st.Choice[host] = e
	delete(r.st.Failed, host)
	r.mu.Unlock()
	r.save()
}

// Forget drops the reader's choice for the site of u.
func (r *Router) Forget(u string) {
	host, _ := site(u)
	r.mu.Lock()
	delete(r.st.Choice, host)
	r.mu.Unlock()
	r.save()
}

func (r *Router) save() {
	if r.path == "" {
		return
	}
	r.mu.Lock()
	b, err := json.Marshal(r.st)
	r.mu.Unlock()
	if err != nil {
		return
	}
	_ = safefile.WriteFile(r.path, b, 0o600)
}
