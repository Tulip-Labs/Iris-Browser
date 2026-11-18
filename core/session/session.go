// Package session is the one cookie store both engines share: Iris owns the
// cookies, not the engines (docs/engines.md). Signing in to a site in one
// engine signs in the other too.
//
// Cookies live in jars: "" is the default, a container has its own
// ("c-work"), and private or temporary tabs use a jar kept in memory only.
// The store follows RFC 6265's matching rules for domain, path, secure and
// expiry; the engines hand it Set-Cookie lines and get cookies back.
package session

import (
	"net/http"
	"net/url"
	"sort"
	"strings"
	"sync"
	"time"
)

// Cookie is one stored cookie.
type Cookie struct {
	Jar      string
	Name     string
	Value    string
	Domain   string // without a leading dot
	HostOnly bool   // set without a Domain attribute: only that host
	Path     string
	Expires  int64 // Unix seconds; 0 for a session cookie
	Secure   bool
	HTTPOnly bool
	SameSite string // "", "Lax", "Strict" or "None"
}

func (c *Cookie) key() string { return c.Jar + "\x00" + c.Domain + "\x00" + c.Path + "\x00" + c.Name }

// SetCookie is the cookie as a Set-Cookie line (what engines take).
func (c *Cookie) SetCookie() string {
	var b strings.Builder
	b.WriteString(c.Name + "=" + c.Value)
	if !c.HostOnly {
		b.WriteString("; Domain=" + c.Domain)
	}
	b.WriteString("; Path=" + c.Path)
	if c.Expires > 0 {
		b.WriteString("; Expires=" + time.Unix(c.Expires, 0).UTC().Format(http.TimeFormat))
	}
	if c.Secure {
		b.WriteString("; Secure")
	}
	if c.HTTPOnly {
		b.WriteString("; HttpOnly")
	}
	if c.SameSite != "" {
		b.WriteString("; SameSite=" + c.SameSite)
	}
	return b.String()
}

// Persister keeps the cookies of lasting jars (sqlitestore).
type Persister interface {
	Load() ([]Cookie, error)
	Put(c Cookie) error
	Delete(c Cookie) error
	Clear(jar string) error
}

// Store is the shared cookie store.
type Store struct {
	mu   sync.Mutex
	all  map[string]*Cookie
	disk Persister
	now  func() time.Time
}

// New makes a store kept by p (nil: in memory only).
func New(p Persister) *Store {
	s := &Store{all: map[string]*Cookie{}, disk: p, now: time.Now}
	if p != nil {
		if cs, err := p.Load(); err == nil {
			for i := range cs {
				c := cs[i]
				s.all[c.key()] = &c
			}
		}
	}
	return s
}

// Memory reports whether jar is kept only in memory (private, temporary and
// sandbox tabs).
func Memory(jar string) bool {
	return strings.HasPrefix(jar, "private") || strings.HasPrefix(jar, "temp") || strings.HasPrefix(jar, "sandbox")
}

// SetFromHeader stores the cookie in a Set-Cookie line that the page at
// address u received, in jar. It reports whether the line was taken.
func (s *Store) SetFromHeader(jar, u, line string) bool {
	pu, err := url.Parse(u)
	if err != nil || pu.Hostname() == "" {
		return false
	}
	hc, err := http.ParseSetCookie(line)
	if err != nil {
		return false
	}
	host := strings.ToLower(pu.Hostname())
	c := Cookie{Jar: jar, Name: hc.Name, Value: hc.Value, Secure: hc.Secure, HTTPOnly: hc.HttpOnly}
	switch hc.SameSite {
	case http.SameSiteLaxMode:
		c.SameSite = "Lax"
	case http.SameSiteStrictMode:
		c.SameSite = "Strict"
	case http.SameSiteNoneMode:
		c.SameSite = "None"
	}
	if d := strings.TrimPrefix(strings.ToLower(hc.Domain), "."); d != "" {
		if !domainMatch(host, d) {
			return false // a site may not set cookies for another
		}
		c.Domain = d
	} else {
		c.Domain, c.HostOnly = host, true
	}
	c.Path = hc.Path
	if c.Path == "" || c.Path[0] != '/' {
		c.Path = defaultPath(pu.Path)
	}
	now := s.now()
	switch {
	case hc.MaxAge < 0:
		c.Expires = -1
	case hc.MaxAge > 0:
		c.Expires = now.Add(time.Duration(hc.MaxAge) * time.Second).Unix()
	case !hc.Expires.IsZero():
		c.Expires = hc.Expires.Unix()
		if c.Expires <= now.Unix() {
			c.Expires = -1
		}
	}
	if c.Secure && pu.Scheme != "https" && host != "localhost" && host != "127.0.0.1" {
		return false
	}
	s.put(c)
	return true
}

// put stores c, or deletes it when it has expired.
func (s *Store) put(c Cookie) {
	s.mu.Lock()
	defer s.mu.Unlock()
	k := c.key()
	if c.Expires < 0 {
		if old, ok := s.all[k]; ok {
			delete(s.all, k)
			if s.disk != nil && !Memory(c.Jar) {
				s.disk.Delete(*old)
			}
		}
		return
	}
	if old, ok := s.all[k]; ok && *old == c {
		return // nothing new: no write
	}
	s.all[k] = &c
	if s.disk != nil && !Memory(c.Jar) {
		s.disk.Put(c)
	}
}

// For returns the cookies of jar that go with a request to address u, in
// the order browsers send them (longer paths first).
func (s *Store) For(jar, u string) []Cookie {
	pu, err := url.Parse(u)
	if err != nil {
		return nil
	}
	host := strings.ToLower(pu.Hostname())
	path := pu.Path
	if path == "" {
		path = "/"
	}
	secure := pu.Scheme == "https"
	now := s.now().Unix()
	s.mu.Lock()
	var out []Cookie
	for k, c := range s.all {
		if c.Jar != jar {
			continue
		}
		if c.Expires > 0 && c.Expires <= now {
			delete(s.all, k)
			if s.disk != nil && !Memory(c.Jar) {
				s.disk.Delete(*c)
			}
			continue
		}
		if c.HostOnly && host != c.Domain || !c.HostOnly && !domainMatch(host, c.Domain) {
			continue
		}
		if !pathMatch(path, c.Path) || c.Secure && !secure {
			continue
		}
		out = append(out, *c)
	}
	s.mu.Unlock()
	sort.SliceStable(out, func(i, j int) bool {
		if len(out[i].Path) != len(out[j].Path) {
			return len(out[i].Path) > len(out[j].Path)
		}
		return out[i].Name < out[j].Name
	})
	return out
}

// Header is the Cookie request header for address u in jar ("" when none).
func (s *Store) Header(jar, u string) string {
	var parts []string
	for _, c := range s.For(jar, u) {
		parts = append(parts, c.Name+"="+c.Value)
	}
	return strings.Join(parts, "; ")
}

// Clear drops every cookie of jar (closing a private window, "clear data").
func (s *Store) Clear(jar string) {
	s.mu.Lock()
	for k, c := range s.all {
		if c.Jar == jar {
			delete(s.all, k)
		}
	}
	s.mu.Unlock()
	if s.disk != nil && !Memory(jar) {
		s.disk.Clear(jar)
	}
}

func domainMatch(host, domain string) bool {
	return host == domain || strings.HasSuffix(host, "."+domain) && !isIP(host)
}

func isIP(h string) bool {
	return strings.Count(h, ".") == 3 && strings.Trim(h, "0123456789.") == "" || strings.Contains(h, ":")
}

func pathMatch(req, cookie string) bool {
	if req == cookie {
		return true
	}
	if strings.HasPrefix(req, cookie) {
		return strings.HasSuffix(cookie, "/") || req[len(cookie)] == '/'
	}
	return false
}

func defaultPath(p string) string {
	if p == "" || p[0] != '/' {
		return "/"
	}
	i := strings.LastIndex(p, "/")
	if i == 0 {
		return "/"
	}
	return p[:i]
}
