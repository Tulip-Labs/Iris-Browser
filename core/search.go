// Package core is Iris's browser logic, independent of the window and the
// web engine: what the address bar opens, the shield, HTTPS-only, tab sleep
// and history. Rules match the original Lite Desktop.
package core

import (
	"net"
	"net/url"
	"regexp"
	"strings"
)

// Mode is a search mode; AI (Google AI Mode) is the default.
type Mode uint8

const (
	ModeAI Mode = iota
	ModeWeb
	ModeImages
	ModeVideos
	ModeYouTube
)

var ModeNames = []string{"AI", "Web", "Images", "Videos", "YouTube"}

const google = "https://www.google.com/search?gl=us&hl=en"

func (m Mode) URL(q string) string {
	e := url.QueryEscape(q)
	switch m {
	case ModeWeb:
		return google + "&udm=14&q=" + e
	case ModeImages:
		return google + "&udm=2&q=" + e
	case ModeVideos:
		return google + "&udm=7&q=" + e
	case ModeYouTube:
		return "https://www.youtube.com/results?search_query=" + e
	}
	return google + "&udm=50&q=" + e
}

var (
	reScheme = regexp.MustCompile(`(?i)^([a-z][a-z0-9+.-]*):(.*)$`)
	rePort   = regexp.MustCompile(`^\d+([/?#]|$)`)
	reYT     = regexp.MustCompile(`(?i)^yt\s+(.+)$`)
)

// privateHostname reports whether a host name (no port) is this computer or
// an address on the local network: localhost and *.localhost, or an IP
// address in the loopback or private ranges. A name that only starts like
// one ("10.example.com", "localhost.example.com", "192.168.evil.net") is a
// public site and gets no exception from HTTPS-only or the address checks.
func privateHostname(h string) bool {
	h = strings.TrimSuffix(strings.ToLower(strings.Trim(h, "[]")), ".")
	if h == "localhost" || strings.HasSuffix(h, ".localhost") {
		return true
	}
	if i := strings.IndexByte(h, '%'); i >= 0 { // fe80::1%eth0
		h = h[:i]
	}
	ip := net.ParseIP(h)
	return ip != nil && (ip.IsLoopback() || ip.IsPrivate())
}

func hasScheme(t string) bool {
	m := reScheme.FindStringSubmatch(t)
	if m == nil || rePort.MatchString(m[2]) {
		return false
	}
	// only schemes a person means to open; "note: milk" is a search, and a
	// pasted javascript: link never runs (the "paste this in your address
	// bar" scam)
	switch strings.ToLower(m[1]) {
	case "http", "https", "file", "about", "view-source", "mailto", "tel":
		return true
	}
	return false
}

// IsURLLike reports whether typed text is an address rather than a search.
func IsURLLike(text string) bool {
	t := strings.TrimSpace(text)
	if t == "" {
		return false
	}
	if hasScheme(t) {
		return true
	}
	// "word:" that is not a port ("localhost:8080") nor a scheme Iris opens is
	// a search (javascript:, data:, notes)
	if m := reScheme.FindStringSubmatch(t); m != nil && !rePort.MatchString(m[2]) {
		return false
	}
	return !strings.Contains(t, " ") && (strings.Contains(t, ".") || t == "localhost" || strings.HasPrefix(strings.ToLower(t), "localhost:"))
}

// URLFor completes an address: https:// unless it is a local address.
func URLFor(text string) string {
	t := strings.TrimSpace(text)
	if hasScheme(t) {
		return t
	}
	host := strings.SplitN(t, "/", 2)[0]
	if i := strings.IndexAny(host, "?#"); i >= 0 {
		host = host[:i]
	}
	if h, _, err := net.SplitHostPort(host); err == nil {
		host = h
	}
	if privateHostname(host) {
		return "http://" + t
	}
	return "https://" + t
}

// Resolve turns address-bar text into the URL to open ("" for empty input).
// "yt cats" searches YouTube whatever the mode.
func Resolve(input string, m Mode) string {
	t := strings.TrimSpace(input)
	if t == "" {
		return ""
	}
	if IsURLLike(t) {
		return URLFor(t)
	}
	if y := reYT.FindStringSubmatch(t); y != nil {
		return ModeYouTube.URL(strings.TrimSpace(y[1]))
	}
	return m.URL(t)
}

// HTTPSUpgrade returns the https:// form of a public http:// address, or "" when none applies.
func HTTPSUpgrade(u string) string {
	if !strings.HasPrefix(strings.ToLower(u), "http://") {
		return ""
	}
	p, err := url.Parse(u)
	if err != nil || p.Hostname() == "" || privateHostname(p.Hostname()) {
		return ""
	}
	return "https://" + u[7:]
}

// IsPrivateHost reports a local network address (allowed over plain http).
func IsPrivateHost(u string) bool {
	p, err := url.Parse(u)
	return err == nil && privateHostname(p.Hostname())
}

// Host returns the lower-case host of a URL ("" if none).
func Host(u string) string {
	p, err := url.Parse(u)
	if err != nil {
		return ""
	}
	return strings.ToLower(p.Hostname())
}

// Display is the short form shown in the address bar when it is not focused.
func Display(u string) string {
	if strings.HasPrefix(u, "https://") {
		u = u[8:]
	}
	u = strings.TrimPrefix(u, "www.")
	return strings.TrimSuffix(u, "/")
}
