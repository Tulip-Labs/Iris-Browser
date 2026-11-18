package link

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
)

func TestLink(t *testing.T) {
	dir := t.TempDir()
	var mu sync.Mutex
	var events []Event
	s, err := Start(filepath.Join(dir, "in"), func(e Event) { mu.Lock(); events = append(events, e); mu.Unlock() })
	if err != nil {
		t.Skip("no network here: ", err)
	}
	defer s.Stop()
	base := s.URL()
	get := func(u string) (int, string) {
		r, err := http.Get(u)
		if err != nil {
			t.Fatal(err)
		}
		defer r.Body.Close()
		b, _ := io.ReadAll(r.Body)
		return r.StatusCode, string(b)
	}
	// without the key there is nothing
	root := base[:strings.Index(base[8:], "/")+8]
	for _, u := range []string{root + "/", root + "/list", root + "/wrongkey/", root + "/wrongkey/list"} {
		if code, _ := get(u); code != 404 {
			t.Fatalf("%s answered %d without the key", u, code)
		}
	}
	if code, body := get(base); code != 200 || !strings.Contains(body, "Iris link") {
		t.Fatalf("page: %d", code)
	}
	// the phone sends a file; its name cannot leave the folder
	payload := bytes.Repeat([]byte("iris web "), 100000)
	r, err := http.Post(base+"up?name=..%2F..%2Fevil%3Aname.txt", "application/octet-stream", bytes.NewReader(payload))
	if err != nil || r.StatusCode != 204 {
		t.Fatalf("upload: %v %v", err, r)
	}
	r.Body.Close()
	got, err := os.ReadFile(filepath.Join(dir, "in", "evil_name.txt"))
	if err != nil || !bytes.Equal(got, payload) {
		t.Fatalf("saved file: %v (%d bytes)", err, len(got))
	}
	// the same name again does not overwrite
	r, _ = http.Post(base+"up?name=evil_name.txt", "application/octet-stream", strings.NewReader("second"))
	r.Body.Close()
	if b, _ := os.ReadFile(filepath.Join(dir, "in", "evil_name (2).txt")); string(b) != "second" {
		t.Fatal("a second file with the same name should be kept beside the first")
	}
	if b, _ := os.ReadFile(filepath.Join(dir, "in", "evil_name.txt")); len(b) != len(payload) {
		t.Fatal("the first file was overwritten")
	}
	// the computer shares a file and a link
	src := filepath.Join(dir, "report final.pdf")
	os.WriteFile(src, []byte("%PDF-1.7 hello"), 0o644)
	if err := s.Share(src); err != nil {
		t.Fatal(err)
	}
	s.ShareText("Example", "https://example.com/")
	_, list := get(base + "list")
	var items []Item
	if json.Unmarshal([]byte(list), &items) != nil || len(items) != 2 || items[0].Name != "report final.pdf" || items[1].Text != "https://example.com/" {
		t.Fatalf("list %s", list)
	}
	if strings.Contains(list, dir) {
		t.Fatal("the list must not tell the phone where files are on the computer")
	}
	if code, body := get(base + "f/1"); code != 200 || body != "%PDF-1.7 hello" {
		t.Fatalf("download %d %q", code, body)
	}
	if code, _ := get(base + "f/2"); code != 404 {
		t.Fatal("text is not a file")
	}
	if code, _ := get(base + "f/../../etc/passwd"); code == 200 {
		t.Fatal("path escape")
	}
	s.Unshare(1)
	if code, _ := get(base + "f/1"); code != 404 {
		t.Fatal("an item taken back must be gone")
	}
	mu.Lock()
	kinds := map[EventKind]int{}
	for _, e := range events {
		kinds[e.Kind]++
	}
	mu.Unlock()
	if kinds[Connected] != 1 || kinds[Received] != 2 || kinds[Fetched] != 1 {
		t.Fatalf("events %v", kinds)
	}
	if s.Phones() != 1 {
		t.Fatal("one phone")
	}
	s.Stop()
	if _, err := http.Get(base); err == nil {
		t.Fatal("a stopped link must not answer")
	}
}

func TestSafeName(t *testing.T) {
	for in, want := range map[string]string{
		"photo.jpg":             "photo.jpg",
		"../../etc/passwd":      "passwd",
		`C:\Users\x\secret.txt`: "secret.txt",
		"a<b>c:d.png":           "a_b_c_d.png",
		"":                      "file",
		"...":                   "file",
		"CON.txt":               "file-CON.txt",
		"nul":                   "file-nul",
		"día de campo.jpeg":     "día de campo.jpeg",
		"x\x00y\n.txt":          "x_y_.txt",
	} {
		if got := SafeName(in); got != want {
			t.Errorf("SafeName(%q) = %q, want %q", in, got, want)
		}
	}
	if n := SafeName(strings.Repeat("ñ", 300) + ".jpg"); len(n) > 190 || !strings.HasSuffix(n, ".jpg") {
		t.Errorf("long name: %d bytes", len(n))
	}
}

func TestSync(t *testing.T) {
	key := NewKey()
	sealed, err := Seal(key, []byte("hello"))
	if err != nil {
		t.Fatal(err)
	}
	if p, err := Open(key, sealed); err != nil || string(p) != "hello" {
		t.Fatalf("round trip: %q %v", p, err)
	}
	if _, err := Open(NewKey(), sealed); err == nil {
		t.Fatal("another key must not open it")
	}
	sealed[len(sealed)-1] ^= 1
	if _, err := Open(key, sealed); err == nil {
		t.Fatal("a changed message must not open")
	}
	var got State
	s, err := StartSync(key, "pc-1", func(in State) State {
		got = in
		return State{Device: "pc-1", Tabs: []Tab{{URL: "https://example.com/"}}, Theme: "mint", ThemeAt: 5}
	})
	if err != nil {
		t.Skip("no network here: ", err)
	}
	defer s.Stop()
	base := "http://127.0.0.1:" + strconv.Itoa(s.Port())
	r, err := http.Get(base + "/sync/hello")
	if err != nil {
		t.Fatal(err)
	}
	b, _ := io.ReadAll(r.Body)
	r.Body.Close()
	if !strings.Contains(string(b), `"app":"iris"`) || strings.Contains(string(b), key) {
		t.Fatalf("hello: %s", b)
	}
	post := func(k string) (int, []byte) {
		in, _ := json.Marshal(State{Device: "phone-1", Name: "Pixel", History: []Visit{{URL: "https://go.dev/", Visits: 2, Last: 100}}})
		body, _ := Seal(k, in)
		r, err := http.Post(base+"/sync/x", "application/octet-stream", bytes.NewReader(body))
		if err != nil {
			t.Fatal(err)
		}
		defer r.Body.Close()
		out, _ := io.ReadAll(r.Body)
		return r.StatusCode, out
	}
	if code, _ := post(NewKey()); code != 403 || got.Device != "" {
		t.Fatalf("a device with another key must be refused: %d", code)
	}
	code, out := post(key)
	plain, err := Open(key, out)
	var reply State
	if code != 200 || err != nil || json.Unmarshal(plain, &reply) != nil || reply.Theme != "mint" || len(reply.Tabs) != 1 {
		t.Fatalf("exchange: %d %v %s", code, err, plain)
	}
	if got.Name != "Pixel" || len(got.History) != 1 {
		t.Fatalf("the computer did not get the phone's state: %+v", got)
	}
	u := PairURL(s.Port(), key, "pc-1")
	if !strings.HasPrefix(u, "iris://pair?") || !strings.Contains(u, "k="+key) {
		t.Fatalf("pair url %s", u)
	}
}
