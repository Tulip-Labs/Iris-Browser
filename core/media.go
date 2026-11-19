package core

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"syscall"
	"time"

	xdraw "golang.org/x/image/draw"
	_ "golang.org/x/image/webp"
)

const browserUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36"

// Client fetches thumbnails, artwork and YouTube results (short timeouts:
// the page never waits on them). Pages name some of these addresses (the
// artwork of what they play), so it only ever connects to public addresses:
// a page cannot make Iris reach this computer or a router on its network,
// not even through a redirect or a name that resolves to one.
var Client = &http.Client{
	Timeout: 12 * time.Second,
	Transport: &http.Transport{
		Proxy:                 http.ProxyFromEnvironment,
		DialContext:           publicDialer(),
		ForceAttemptHTTP2:     true,
		MaxIdleConns:          8,
		IdleConnTimeout:       60 * time.Second,
		TLSHandshakeTimeout:   10 * time.Second,
		ResponseHeaderTimeout: 10 * time.Second,
	},
	CheckRedirect: func(req *http.Request, via []*http.Request) error {
		if len(via) >= 5 {
			return errors.New("too many redirects")
		}
		if req.URL.Scheme != "https" && req.URL.Scheme != "http" {
			return errors.New("redirect to an unsupported scheme")
		}
		return nil
	},
}

// publicDialer connects only to public addresses. The proxy named in the
// environment (often on this computer) is the one exception: requests then
// go through it.
func publicDialer() func(ctx context.Context, network, addr string) (net.Conn, error) {
	proxies := map[string]bool{}
	for _, scheme := range []string{"http", "https"} {
		req := &http.Request{URL: &url.URL{Scheme: scheme, Host: "example.com"}}
		if p, err := http.ProxyFromEnvironment(req); err == nil && p != nil {
			host, port := p.Hostname(), p.Port()
			if port == "" {
				port = map[string]string{"http": "80", "https": "443", "socks5": "1080"}[p.Scheme]
			}
			proxies[net.JoinHostPort(host, port)] = true
		}
	}
	d := &net.Dialer{Timeout: 8 * time.Second, KeepAlive: 30 * time.Second}
	guarded := &net.Dialer{Timeout: 8 * time.Second, KeepAlive: 30 * time.Second,
		Control: func(network, address string, _ syscall.RawConn) error {
			host, _, err := net.SplitHostPort(address)
			if err != nil {
				return err
			}
			if ip := net.ParseIP(host); ip == nil || !PublicIP(ip) {
				return fmt.Errorf("not a public address: %s", host)
			}
			return nil
		}}
	return func(ctx context.Context, network, addr string) (net.Conn, error) {
		if proxies[addr] {
			return d.DialContext(ctx, network, addr)
		}
		return guarded.DialContext(ctx, network, addr)
	}
}

// PublicIP reports whether ip is an address on the internet: not this
// computer, not the local network, not link-local, multicast or unspecified.
func PublicIP(ip net.IP) bool {
	if v4 := ip.To4(); v4 != nil {
		ip = v4
		// 0.0.0.0/8, 100.64.0.0/10 (carrier NAT), 192.0.0.0/24, 198.18.0.0/15, 240.0.0.0/4
		switch {
		case v4[0] == 0, v4[0] == 100 && v4[1]&0xC0 == 64, v4[0] == 192 && v4[1] == 0 && v4[2] == 0,
			v4[0] == 198 && v4[1]&0xFE == 18, v4[0] >= 240:
			return false
		}
	}
	return ip.IsGlobalUnicast() && !ip.IsPrivate()
}

// maxPixels is the largest picture Iris decodes (about 40 megapixels, 160
// MB as RGBA). A small file can claim a huge size; such a picture is refused
// before any memory is taken for it.
const maxPixels = 40 << 20

func get(ctx context.Context, u string, limit int64) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", u, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", browserUA)
	req.Header.Set("Accept-Language", "en-US,en;q=0.9")
	resp, err := Client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return nil, errors.New(resp.Status)
	}
	return io.ReadAll(io.LimitReader(resp.Body, limit))
}

// FetchImage loads a thumbnail (an https address or a data: URI) and scales it
// down to at most maxW pixels wide, so pictures stay light in memory.
func FetchImage(ctx context.Context, src string, maxW int) (image.Image, error) {
	var b []byte
	if strings.HasPrefix(src, "data:") {
		i := strings.Index(src, ",")
		if i < 0 || !strings.Contains(src[:i], ";base64") {
			return nil, errors.New("bad data address")
		}
		if len(src)-i > 6<<20 {
			return nil, errors.New("picture too large")
		}
		var err error
		if b, err = base64.StdEncoding.DecodeString(src[i+1:]); err != nil {
			return nil, err
		}
	} else {
		var err error
		if b, err = get(ctx, src, 4<<20); err != nil {
			return nil, err
		}
	}
	return decodeScaled(b, maxW)
}

// decodeScaled decodes a picture and scales it down to at most maxW pixels
// wide; pictures too large to decode safely are refused.
func decodeScaled(b []byte, maxW int) (image.Image, error) {
	cfg, _, err := image.DecodeConfig(bytes.NewReader(b))
	if err != nil {
		return nil, err
	}
	if cfg.Width <= 0 || cfg.Height <= 0 || cfg.Width > 16384 || cfg.Height > 16384 || cfg.Width*cfg.Height > maxPixels {
		return nil, errors.New("picture too large")
	}
	img, _, err := image.Decode(bytes.NewReader(b))
	if err != nil {
		return nil, err
	}
	maxW = max(1, maxW)
	// always one compact RGBA copy at display size: the drawing layer uses it
	// as is (no second copy), and the decoded original is let go
	bd := img.Bounds()
	w := min(bd.Dx(), maxW)
	h := max(1, bd.Dy()*w/max(1, bd.Dx()))
	dst := image.NewRGBA(image.Rect(0, 0, w, h))
	xdraw.ApproxBiLinear.Scale(dst, dst.Bounds(), img, bd, xdraw.Src, nil)
	return dst, nil
}

// YouTubeSearch reads the first videos YouTube shows for q.
func YouTubeSearch(ctx context.Context, q string) ([]VideoResult, error) {
	b, err := get(ctx, "https://www.youtube.com/results?hl=en&gl=US&search_query="+url.QueryEscape(q), 6<<20)
	if err != nil {
		return nil, err
	}
	return ParseYouTube(string(b))
}

// ParseYouTube reads the videos from a YouTube results page (its ytInitialData).
func ParseYouTube(html string) ([]VideoResult, error) {
	i := strings.Index(html, "ytInitialData")
	if i < 0 {
		return nil, errors.New("no results data")
	}
	j := strings.IndexByte(html[i:], '{')
	if j < 0 {
		return nil, errors.New("no results data")
	}
	dec := json.NewDecoder(strings.NewReader(html[i+j:]))
	var data any
	if err := dec.Decode(&data); err != nil {
		return nil, err
	}
	var out []VideoResult
	var walk func(v any)
	walk = func(v any) {
		if len(out) >= 16 {
			return
		}
		switch x := v.(type) {
		case map[string]any:
			if vr, ok := x["videoRenderer"].(map[string]any); ok {
				if v := video(vr); v.ID != "" {
					out = append(out, v)
				}
				return
			}
			for _, c := range x {
				walk(c)
			}
		case []any:
			for _, c := range x {
				walk(c)
			}
		}
	}
	walk(data)
	return out, nil
}

func text(v any) string {
	m, ok := v.(map[string]any)
	if !ok {
		return ""
	}
	if s, ok := m["simpleText"].(string); ok {
		return s
	}
	if runs, ok := m["runs"].([]any); ok {
		var sb strings.Builder
		for _, r := range runs {
			if rm, ok := r.(map[string]any); ok {
				if s, ok := rm["text"].(string); ok {
					sb.WriteString(s)
				}
			}
		}
		return sb.String()
	}
	return ""
}

func video(m map[string]any) VideoResult {
	id, _ := m["videoId"].(string)
	return VideoResult{ID: id, Title: text(m["title"]), Channel: text(m["ownerText"]), Length: text(m["lengthText"]),
		Views: text(m["shortViewCountText"]), Age: text(m["publishedTimeText"])}
}
