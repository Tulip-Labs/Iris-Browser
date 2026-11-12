package core

import (
	"database/sql"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"os"

	"github.com/ncruces/go-sqlite3"
	_ "github.com/ncruces/go-sqlite3/driver" // pure-Go SQLite (WebAssembly run by wazero)
	_ "github.com/ncruces/go-sqlite3/embed"
	"github.com/tetratelabs/wazero"
)

// Entry is a visited page.
type Entry struct {
	URL, Title string
	Visits     int
	Last       time.Time
}

// History keeps visited pages in SQLite (never for private tabs). It opens in
// the background; until then, and if the disk fails, it works in memory.
type History struct {
	mu    sync.Mutex
	db    *sql.DB
	mem   map[string]*Entry
	ready chan struct{}
}

// OpenHistory starts opening history.sqlite in dir ("" = memory only).
func OpenHistory(dir string) *History {
	h := &History{mem: map[string]*Entry{}, ready: make(chan struct{})}
	if dir == "" {
		close(h.ready)
		return h
	}
	go func() {
		defer close(h.ready)
		// SQLite's compiled code is cached on disk: only the first launch compiles it
		cacheDir := filepath.Join(dir, "cache", "sqlite")
		if os.MkdirAll(cacheDir, 0o755) == nil {
			if cache, err := wazero.NewCompilationCacheWithDir(cacheDir); err == nil {
				sqlite3.RuntimeConfig = wazero.NewRuntimeConfig().WithCompilationCache(cache)
			}
		}
		db, err := sql.Open("sqlite3", "file:"+filepath.ToSlash(filepath.Join(dir, "history.sqlite"))+"?_pragma=journal_mode(WAL)&_pragma=synchronous(NORMAL)")
		if err != nil {
			return
		}
		db.SetMaxOpenConns(1)
		if _, err := db.Exec(`CREATE TABLE IF NOT EXISTS visits (url TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '', visits INTEGER NOT NULL DEFAULT 1, last INTEGER NOT NULL)`); err != nil {
			db.Close()
			return
		}
		rows, err := db.Query(`SELECT url, title, visits, last FROM visits ORDER BY last DESC LIMIT 5000`)
		if err == nil {
			h.mu.Lock()
			for rows.Next() {
				var e Entry
				var last int64
				if rows.Scan(&e.URL, &e.Title, &e.Visits, &last) == nil {
					e.Last = time.Unix(last, 0)
					if _, seen := h.mem[e.URL]; !seen {
						ec := e
						h.mem[e.URL] = &ec
					}
				}
			}
			rows.Close()
			h.mu.Unlock()
		}
		h.mu.Lock()
		h.db = db
		h.mu.Unlock()
	}()
	return h
}

// Add records a visit (title may be updated later with the same call).
func (h *History) Add(url, title string, countVisit bool) {
	if url == "" || strings.HasPrefix(url, "about:") || strings.HasPrefix(url, "data:") {
		return
	}
	h.mu.Lock()
	e := h.mem[url]
	if e == nil {
		e = &Entry{URL: url}
		h.mem[url] = e
		countVisit = true
	}
	if countVisit {
		e.Visits++
	}
	if title != "" {
		e.Title = title
	}
	e.Last = time.Now()
	db, ec := h.db, *e
	h.mu.Unlock()
	if db != nil {
		go db.Exec(`INSERT INTO visits (url, title, visits, last) VALUES (?, ?, ?, ?)
			ON CONFLICT(url) DO UPDATE SET title = excluded.title, visits = excluded.visits, last = excluded.last`,
			ec.URL, ec.Title, ec.Visits, ec.Last.Unix())
	}
}

func score(e *Entry) float64 {
	age := time.Since(e.Last).Hours() / 24
	return float64(e.Visits) / (1 + age/7)
}

// Suggest returns entries whose address or title contains text, best first.
func (h *History) Suggest(text string, n int) []Entry {
	t := strings.ToLower(strings.TrimSpace(text))
	if t == "" {
		return nil
	}
	h.mu.Lock()
	var out []*Entry
	for _, e := range h.mem {
		u := strings.ToLower(Display(e.URL))
		if strings.HasPrefix(u, t) || strings.Contains(u, t) || strings.Contains(strings.ToLower(e.Title), t) {
			out = append(out, e)
		}
	}
	h.mu.Unlock()
	return best(out, n, func(e *Entry) float64 {
		s := score(e)
		if strings.HasPrefix(strings.ToLower(Display(e.URL)), t) {
			s *= 4 // what you are typing the start of comes first
		}
		return s
	})
}

// Top returns the most visited sites (one entry per host).
func (h *History) Top(n int) []Entry {
	h.mu.Lock()
	byHost := map[string]*Entry{}
	for _, e := range h.mem {
		host := Host(e.URL)
		if host == "" {
			continue
		}
		if b := byHost[host]; b == nil || score(e) > score(b) {
			byHost[host] = e
		}
	}
	var all []*Entry
	for _, e := range byHost {
		all = append(all, e)
	}
	h.mu.Unlock()
	return best(all, n, score)
}

func best(es []*Entry, n int, key func(*Entry) float64) []Entry {
	// small n: selection is enough
	var out []Entry
	used := make([]bool, len(es))
	for len(out) < n {
		bi := -1
		for i, e := range es {
			if !used[i] && (bi < 0 || key(e) > key(es[bi])) {
				bi = i
			}
		}
		if bi < 0 {
			break
		}
		used[bi] = true
		out = append(out, *es[bi])
	}
	return out
}

// Clear forgets everything.
func (h *History) Clear() {
	h.mu.Lock()
	h.mem = map[string]*Entry{}
	db := h.db
	h.mu.Unlock()
	if db != nil {
		go db.Exec(`DELETE FROM visits`)
	}
}

// Wait blocks until the database is open (tests).
func (h *History) Wait() { <-h.ready }
