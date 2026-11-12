package core

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"image"
	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	xdraw "golang.org/x/image/draw"
	_ "golang.org/x/image/webp"
)

const browserUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36"

// Client fetches thumbnails and YouTube results (short timeouts: the page never waits on them).
var Client = &http.Client{Timeout: 12 * time.Second}

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
		if i < 0 {
			return nil, errors.New("bad data address")
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
	img, _, err := image.Decode(bytes.NewReader(b))
	if err != nil {
		return nil, err
	}
	bd := img.Bounds()
	if bd.Dx() <= maxW {
		return img, nil
	}
	h := bd.Dy() * maxW / bd.Dx()
	dst := image.NewRGBA(image.Rect(0, 0, maxW, max(1, h)))
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
