// Package link moves files between this computer and a phone on the same
// network, with nothing to install on the phone: Iris serves one small
// page on the local network, the phone opens it by scanning a QR code, and
// sends or fetches files from its own browser.
//
// The address carries a random key, so only who scanned the code (or was
// given the address) gets in, and the page is served only while the link is
// on. The connection is plain HTTP inside the local network: it never leaves
// it, but it is not encrypted, so it is for networks you trust.
package link

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base32"
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// EventKind says what happened on the link.
type EventKind uint8

const (
	Connected EventKind = iota // the phone opened the page
	Receiving                  // a file from the phone is arriving (and its progress)
	Received                   // it is saved
	Failed                     // it did not arrive whole
	Fetched                    // the phone took a shared file
)

// Event reports what the phone does. ID identifies one incoming file.
type Event struct {
	Kind      EventKind
	ID        int
	Name      string
	Path      string
	Size, Got int64 // Size is -1 when the phone did not say
}

// Item is something shared with the phone: a file, or a piece of text (a link).
type Item struct {
	ID   int    `json:"id"`
	Name string `json:"name"`
	Size int64  `json:"size"`
	Text string `json:"text,omitempty"`
	path string
}

// Server is a running link.
type Server struct {
	ln     net.Listener
	srv    *http.Server
	key    string
	host   string
	dir    string
	notify func(Event)

	mu     sync.Mutex
	items  []*Item
	nextID int
	inID   int
	seen   time.Time
	phones map[string]bool
	pair   string // iris://pair?... when sync is on
}

// Start opens the link. Files from the phone are saved in dir; notify is
// called from the server's goroutines.
func Start(dir string, notify func(Event)) (*Server, error) {
	ip := lanIP()
	if ip == "" {
		return nil, errors.New("this computer is not on a network")
	}
	ln, err := net.Listen("tcp4", net.JoinHostPort(ip, "0"))
	if err != nil {
		return nil, err
	}
	raw := make([]byte, 10)
	if _, err := rand.Read(raw); err != nil {
		ln.Close()
		return nil, err
	}
	s := &Server{ln: ln, dir: dir, notify: notify, seen: time.Now(), phones: map[string]bool{},
		key:  strings.ToLower(base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(raw)),
		host: ln.Addr().String()}
	s.srv = &http.Server{Handler: http.HandlerFunc(s.serve), ReadHeaderTimeout: 10 * time.Second}
	go s.srv.Serve(ln)
	return s, nil
}

// URL is the address the QR code carries.
func (s *Server) URL() string { return "http://" + s.host + "/" + s.key + "/" }

// Stop closes the link; transfers under way are cut.
func (s *Server) Stop() { _ = s.srv.Close() }

// Idle is how long ago the phone last asked for anything.
func (s *Server) Idle() time.Duration {
	s.mu.Lock()
	defer s.mu.Unlock()
	return time.Since(s.seen)
}

// Phones is how many devices have opened the page.
func (s *Server) Phones() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.phones)
}

// Share offers a file to the phone.
func (s *Server) Share(path string) error {
	st, err := os.Stat(path)
	if err != nil {
		return err
	}
	if st.IsDir() {
		return errors.New("folders cannot be sent, only files")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, it := range s.items {
		if it.path == path {
			return nil
		}
	}
	s.nextID++
	s.items = append(s.items, &Item{ID: s.nextID, Name: filepath.Base(path), Size: st.Size(), path: path})
	return nil
}

// ShareText offers a piece of text (a link, a note) under a title.
func (s *Server) ShareText(title, text string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, it := range s.items {
		if it.Text == text {
			return
		}
	}
	s.nextID++
	s.items = append(s.items, &Item{ID: s.nextID, Name: title, Text: text})
}

// Unshare takes an item back.
func (s *Server) Unshare(id int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i, it := range s.items {
		if it.ID == id {
			s.items = append(s.items[:i], s.items[i+1:]...)
			return
		}
	}
}

// Items lists what is shared.
func (s *Server) Items() []Item {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]Item, len(s.items))
	for i, it := range s.items {
		out[i] = *it
	}
	return out
}

func (s *Server) serve(w http.ResponseWriter, r *http.Request) {
	// everything lives under /<key>/; anything else does not exist
	rest, ok := strings.CutPrefix(r.URL.Path, "/")
	key, rest, _ := strings.Cut(rest, "/")
	if !ok || subtle.ConstantTimeCompare([]byte(key), []byte(s.key)) != 1 {
		http.NotFound(w, r)
		return
	}
	who, _, _ := net.SplitHostPort(r.RemoteAddr)
	s.mu.Lock()
	s.seen = time.Now()
	first := !s.phones[who]
	s.phones[who] = true
	s.mu.Unlock()
	if first && s.notify != nil {
		s.notify(Event{Kind: Connected, Name: who})
	}
	h := w.Header()
	h.Set("Cache-Control", "no-store")
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Referrer-Policy", "no-referrer")
	switch {
	case rest == "" && r.Method == http.MethodGet:
		h.Set("Content-Type", "text/html; charset=utf-8")
		h.Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; form-action 'none'; base-uri 'none'")
		name, _ := os.Hostname()
		s.mu.Lock()
		pair := s.pair
		s.mu.Unlock()
		out := strings.Replace(page, "{{PC}}", htmlEscape(name), 1)
		js, _ := json.Marshal(pair) // a JavaScript string, with < > & escaped
		io.WriteString(w, strings.Replace(out, `"{{PAIR}}"`, string(js), 1))
	case rest == "list" && r.Method == http.MethodGet:
		h.Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(s.Items())
	case rest == "up" && r.Method == http.MethodPost:
		s.receive(w, r)
	case strings.HasPrefix(rest, "f/") && r.Method == http.MethodGet:
		s.send(w, r, strings.TrimPrefix(rest, "f/"))
	default:
		http.NotFound(w, r)
	}
}

func (s *Server) send(w http.ResponseWriter, r *http.Request, id string) {
	n, _ := strconv.Atoi(id)
	var it *Item
	s.mu.Lock()
	for _, x := range s.items {
		if x.ID == n && x.path != "" {
			it = x
		}
	}
	s.mu.Unlock()
	if it == nil {
		http.NotFound(w, r)
		return
	}
	f, err := os.Open(it.path)
	if err != nil {
		http.Error(w, "the file is no longer there", http.StatusGone)
		return
	}
	defer f.Close()
	st, _ := f.Stat()
	w.Header().Set("Content-Disposition", mime.FormatMediaType("attachment", map[string]string{"filename": it.Name}))
	http.ServeContent(w, r, it.Name, st.ModTime(), f)
	if s.notify != nil && r.Header.Get("Range") == "" {
		s.notify(Event{Kind: Fetched, ID: it.ID, Name: it.Name, Path: it.path, Size: it.Size})
	}
}

// receive saves one file sent by the phone (the body is the file itself).
func (s *Server) receive(w http.ResponseWriter, r *http.Request) {
	name := SafeName(r.URL.Query().Get("name"))
	if err := os.MkdirAll(s.dir, 0o755); err != nil {
		http.Error(w, "cannot save here", http.StatusInternalServerError)
		return
	}
	s.mu.Lock()
	s.inID++
	id := s.inID
	s.mu.Unlock()
	// at most 16 GB from one phone upload, so a sender cannot fill the disk
	r.Body = http.MaxBytesReader(w, r.Body, 16<<30)
	// the name is claimed atomically (O_EXCL): two uploads of one name never
	// share a file
	var path, part string
	var f *os.File
	var err error
	for try := 0; try < 20; try++ {
		path = freePath(s.dir, name)
		part = path + ".part"
		if f, err = os.OpenFile(part, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644); err == nil || !os.IsExist(err) {
			break
		}
	}
	if err != nil {
		http.Error(w, "cannot save here", http.StatusInternalServerError)
		return
	}
	ev := Event{Kind: Receiving, ID: id, Name: filepath.Base(path), Path: path, Size: r.ContentLength}
	tell := func() {
		if s.notify != nil {
			s.notify(ev)
		}
	}
	tell()
	buf := make([]byte, 256<<10)
	last := time.Now()
	var werr error
	for werr == nil {
		n, rerr := r.Body.Read(buf)
		if n > 0 {
			_, werr = f.Write(buf[:n])
			ev.Got += int64(n)
			if time.Since(last) > 200*time.Millisecond {
				last = time.Now()
				s.mu.Lock()
				s.seen = last
				s.mu.Unlock()
				tell()
			}
		}
		if rerr != nil {
			if rerr != io.EOF {
				werr = rerr
			}
			break
		}
	}
	cerr := f.Close()
	if werr == nil && cerr == nil && (ev.Size < 0 || ev.Got == ev.Size) {
		if _, e := os.Lstat(path); e == nil {
			path = freePath(s.dir, filepath.Base(path))
			ev.Path, ev.Name = path, filepath.Base(path)
		}
		werr = os.Rename(part, path)
	} else if werr == nil {
		werr = errors.New("incomplete")
	}
	if werr != nil {
		_ = os.Remove(part)
		ev.Kind = Failed
		tell()
		http.Error(w, "the file did not arrive whole", http.StatusBadRequest)
		return
	}
	ev.Kind, ev.Size = Received, ev.Got
	tell()
	w.WriteHeader(http.StatusNoContent)
}

// SafeName turns a name given by the phone into a plain file name: no
// folders, no control characters, nothing Windows refuses, never empty.
func SafeName(name string) string {
	if u, err := url.PathUnescape(name); err == nil {
		name = u
	}
	name = strings.ReplaceAll(name, "\\", "/")
	if i := strings.LastIndexByte(name, '/'); i >= 0 {
		name = name[i+1:]
	}
	var b strings.Builder
	for _, r := range name {
		switch {
		case r < 32 || r == 127, strings.ContainsRune(`<>:"/\|?*`, r):
			b.WriteByte('_')
		default:
			b.WriteRune(r)
		}
	}
	name = strings.Trim(strings.TrimSpace(b.String()), ".")
	if len(name) > 180 {
		ext := filepath.Ext(name)
		if len(ext) > 12 {
			ext = ""
		}
		cut := 180 - len(ext)
		for cut > 0 && name[cut]&0xC0 == 0x80 { // not in the middle of a character
			cut--
		}
		name = name[:cut] + ext
	}
	stem := strings.ToUpper(strings.TrimSuffix(name, filepath.Ext(name)))
	switch stem {
	case "", "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "LPT1", "LPT2", "LPT3":
		name = "file-" + name
	}
	if name == "file-" {
		name = "file"
	}
	return name
}

// freePath is dir/name, or dir/"name (2).ext" and so on when that is taken.
func freePath(dir, name string) string {
	p := filepath.Join(dir, name)
	ext := filepath.Ext(name)
	stem := strings.TrimSuffix(name, ext)
	for n := 2; n < 10000; n++ {
		if _, err := os.Lstat(p); err != nil {
			if _, err := os.Lstat(p + ".part"); err != nil {
				return p
			}
		}
		p = filepath.Join(dir, stem+" ("+strconv.Itoa(n)+")"+ext)
	}
	return p
}

// lanIP is this computer's address on the local network ("" if none).
func lanIP() string {
	best := ""
	ifs, _ := net.Interfaces()
	for _, in := range ifs {
		if in.Flags&net.FlagUp == 0 || in.Flags&net.FlagLoopback != 0 || in.Flags&net.FlagPointToPoint != 0 {
			continue
		}
		addrs, _ := in.Addrs()
		for _, a := range addrs {
			n, ok := a.(*net.IPNet)
			if !ok {
				continue
			}
			ip := n.IP.To4()
			if ip == nil || !ip.IsPrivate() {
				continue
			}
			// home and office networks first; virtual adapters often sit in 172.16/12
			if ip[0] == 192 || best == "" || (ip[0] == 10 && !strings.HasPrefix(best, "192.")) {
				if !(strings.HasPrefix(best, "192.") && ip[0] != 192) {
					best = ip.String()
				}
			}
		}
	}
	if best != "" {
		return best
	}
	// no private address: ask the system which one it would use to go out
	// (nothing is sent)
	if c, err := net.Dial("udp4", "192.0.2.1:9"); err == nil {
		defer c.Close()
		if a, ok := c.LocalAddr().(*net.UDPAddr); ok && !a.IP.IsLoopback() {
			return a.IP.String()
		}
	}
	return ""
}

func htmlEscape(s string) string {
	return strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", `"`, "&quot;").Replace(s)
}
