package core

import (
	"net"
	"net/url"
	"strings"
)

// names that phishing pages borrow, with the sites that really carry them
var brands = map[string][]string{
	"paypal":      {"paypal.com", "paypal.me"},
	"google":      {"google.com", "google.dev", "withgoogle.com", "goo.gl"},
	"gmail":       {"gmail.com", "google.com"},
	"microsoft":   {"microsoft.com", "live.com", "azure.com", "office.com"},
	"outlook":     {"outlook.com", "live.com", "office.com"},
	"office365":   {"office365.com", "office.com", "microsoft.com"},
	"icloud":      {"icloud.com", "apple.com"},
	"facebook":    {"facebook.com", "fb.com", "meta.com"},
	"instagram":   {"instagram.com"},
	"whatsapp":    {"whatsapp.com", "whatsapp.net"},
	"netflix":     {"netflix.com"},
	"binance":     {"binance.com", "binance.us"},
	"coinbase":    {"coinbase.com"},
	"metamask":    {"metamask.io"},
	"linkedin":    {"linkedin.com"},
	"github":      {"github.com", "github.io", "github.dev", "githubusercontent.com"},
	"dropbox":     {"dropbox.com", "dropboxusercontent.com"},
	"spotify":     {"spotify.com"},
	"roblox":      {"roblox.com"},
	"bancolombia": {"bancolombia.com", "grupobancolombia.com"},
	"nequi":       {"nequi.com.co", "nequi.com"},
	"davivienda":  {"davivienda.com"},
}

var secondLevel = map[string]bool{"co": true, "com": true, "org": true, "net": true, "gov": true, "edu": true, "ac": true, "gob": true}

// site is the registered name of a host: example.com, example.co.uk.
func site(host string) string {
	p := strings.Split(host, ".")
	n := len(p)
	if n <= 2 {
		return host
	}
	if len(p[n-1]) == 2 && secondLevel[p[n-2]] {
		return strings.Join(p[n-3:], ".")
	}
	return strings.Join(p[n-2:], ".")
}

// Risk says, in a few words, why an address looks unsafe; "" when nothing
// about it does. It only reads the address: a hidden real site, a bare
// network address, look-alike letters, or a known name on someone else's
// site. It cannot tell what a page does, so "" is not a promise of safety.
func Risk(u string) string {
	p, err := url.Parse(u)
	if err != nil || (p.Scheme != "http" && p.Scheme != "https") {
		return ""
	}
	host := strings.ToLower(p.Hostname())
	if host == "" || IsPrivateHost(u) {
		return ""
	}
	if p.User != nil {
		return "the address puts another name in front of the real site (" + host + ")"
	}
	if ip := net.ParseIP(host); ip != nil {
		return "it is a bare network address, not a named site"
	}
	for _, l := range strings.Split(host, ".") {
		if strings.HasPrefix(l, "xn--") {
			return "its name uses letters of another alphabet, which can imitate a known site"
		}
	}
	reg := site(host)
	main := reg
	if i := strings.IndexByte(reg, '.'); i > 0 {
		main = reg[:i]
	}
	for _, tok := range strings.FieldsFunc(host, func(r rune) bool { return r == '.' || r == '-' }) {
		own, ok := brands[tok]
		if !ok || main == tok {
			continue
		}
		mine := false
		for _, d := range own {
			if reg == d {
				mine = true
			}
		}
		if !mine {
			return "it uses the name " + tok + " but belongs to " + reg
		}
	}
	return ""
}
