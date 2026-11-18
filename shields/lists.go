package shields

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"time"
)

// List is a filter list Iris downloads (never bundled: each keeps its own
// license and authors) and refreshes every few days.
type List struct {
	ID, Name string
	URLs     []string // the first that answers wins
}

// Lists are the lists Iris Shields uses.
var Lists = []List{
	{"easylist", "EasyList (ads)", []string{"https://easylist.to/easylist/easylist.txt", "https://ublockorigin.github.io/uAssets/thirdparties/easylist.txt"}},
	{"easyprivacy", "EasyPrivacy (trackers)", []string{"https://easylist.to/easylist/easyprivacy.txt", "https://ublockorigin.github.io/uAssets/thirdparties/easyprivacy.txt"}},
	{"ublock", "uBlock filters", []string{"https://ublockorigin.github.io/uAssets/filters/filters.txt", "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/filters.txt"}},
	{"cookies", "EasyList Cookie (cookie notices)", []string{"https://secure.fanboy.co.nz/fanboy-cookiemonster.txt", "https://ublockorigin.github.io/uAssets/thirdparties/easylist-cookies.txt"}},
}

// MaxAge is how old a downloaded list may get before it is fetched again.
const MaxAge = 4 * 24 * time.Hour

var client = &http.Client{Timeout: 40 * time.Second}

func fetch(ctx context.Context, urls []string) ([]byte, error) {
	var last error
	for _, u := range urls {
		req, err := http.NewRequestWithContext(ctx, "GET", u, nil)
		if err != nil {
			return nil, err
		}
		req.Header.Set("User-Agent", "Iris/1.0 (filter lists)")
		resp, err := client.Do(req)
		if err != nil {
			last = err
			continue
		}
		b, err := io.ReadAll(io.LimitReader(resp.Body, 16<<20))
		resp.Body.Close()
		if err != nil || resp.StatusCode != 200 {
			last = errors.New(resp.Status)
			continue
		}
		if !bytes.Contains(b[:min(len(b), 4096)], []byte("!")) {
			last = errors.New("not a filter list")
			continue
		}
		return b, nil
	}
	return nil, last
}

// Load builds an engine from the lists saved in dir, and fetches lists that
// are missing or old (when refresh is set). wanted picks the lists by ID.
func Load(ctx context.Context, dir string, wanted map[string]bool, refresh bool) (*Engine, time.Time, error) {
	e := New()
	var newest time.Time
	var firstErr error
	_ = os.MkdirAll(dir, 0o755)
	for _, l := range Lists {
		if !wanted[l.ID] {
			continue
		}
		p := filepath.Join(dir, l.ID+".txt")
		st, err := os.Stat(p)
		if refresh && (err != nil || time.Since(st.ModTime()) > MaxAge) {
			if b, ferr := fetch(ctx, l.URLs); ferr == nil {
				tmp := p + ".tmp"
				if os.WriteFile(tmp, b, 0o644) == nil {
					_ = os.Rename(tmp, p)
				}
			} else if firstErr == nil {
				firstErr = ferr
			}
		}
		f, err := os.Open(p)
		if err != nil {
			continue
		}
		e.Add(f)
		f.Close()
		if st, err := os.Stat(p); err == nil && st.ModTime().After(newest) {
			newest = st.ModTime()
		}
	}
	return e, newest, firstErr
}
