package link

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"time"
)

// Sync between Iris and Iris for Android, with no server in between: the
// two meet on the local network and trade what they know. Everything they
// send is sealed with a key they share from the pairing (AES-256-GCM), so
// nobody else on the network can read or change it.

// SyncPort is the first port tried; the phone looks for the computer there.
const SyncPort = 47600

// State is what one device tells the other.
type State struct {
	Device  string  `json:"device"`
	Name    string  `json:"name"`
	Tabs    []Tab   `json:"tabs"`
	History []Visit `json:"history"`
	Theme   string  `json:"theme,omitempty"`
	ThemeAt int64   `json:"themeAt,omitempty"`
}

type Tab struct {
	URL   string `json:"url"`
	Title string `json:"title,omitempty"`
}

type Visit struct {
	URL    string `json:"u"`
	Title  string `json:"t,omitempty"`
	Visits int    `json:"v"`
	Last   int64  `json:"l"`
}

// bound into every message; kept from when Iris was Lite Go, so devices on
// either version still understand each other
const syncAAD = "litego-sync-1"

// NewKey makes a pairing key (hex).
func NewKey() string {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}

// Seal encrypts plain with the pairing key: a 12-byte nonce, then the sealed text.
func Seal(keyHex string, plain []byte) ([]byte, error) {
	g, err := gcm(keyHex)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, g.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	return g.Seal(nonce, nonce, plain, []byte(syncAAD)), nil
}

// Open reverses Seal; it fails when the key is not the one that sealed it.
func Open(keyHex string, data []byte) ([]byte, error) {
	g, err := gcm(keyHex)
	if err != nil {
		return nil, err
	}
	if len(data) < g.NonceSize() {
		return nil, errors.New("too short")
	}
	return g.Open(nil, data[:g.NonceSize()], data[g.NonceSize():], []byte(syncAAD))
}

func gcm(keyHex string) (cipher.AEAD, error) {
	key, err := hex.DecodeString(keyHex)
	if err != nil || len(key) != 32 {
		return nil, errors.New("bad key")
	}
	b, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(b)
}

// SyncServer is the computer's side: it waits for the paired phone.
type SyncServer struct {
	srv  *http.Server
	port int
}

// StartSync listens for paired devices. exchange is given what the other
// device knows and returns what this one knows; it runs on a server goroutine.
func StartSync(keyHex, device string, exchange func(State) State) (*SyncServer, error) {
	if _, err := gcm(keyHex); err != nil {
		return nil, err
	}
	var ln net.Listener
	var err error
	port := SyncPort
	for ; port < SyncPort+8; port++ {
		if ln, err = net.Listen("tcp4", ":"+strconv.Itoa(port)); err == nil {
			break
		}
	}
	if err != nil {
		return nil, err
	}
	name, _ := os.Hostname()
	mux := http.NewServeMux()
	// who is here: lets the phone find the computer again when its address changes
	mux.HandleFunc("/sync/hello", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]string{"app": "iris", "id": device, "name": name})
	})
	mux.HandleFunc("/sync/x", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.NotFound(w, r)
			return
		}
		body, err := io.ReadAll(io.LimitReader(r.Body, 8<<20))
		if err != nil {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		plain, err := Open(keyHex, body)
		if err != nil {
			http.Error(w, "not paired", http.StatusForbidden) // not our key: says nothing more
			return
		}
		var in State
		if json.Unmarshal(plain, &in) != nil || in.Device == "" {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		out, _ := json.Marshal(exchange(in))
		sealed, err := Seal(keyHex, out)
		if err != nil {
			http.Error(w, "error", http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/octet-stream")
		_, _ = w.Write(sealed)
	})
	s := &SyncServer{srv: &http.Server{Handler: mux, ReadHeaderTimeout: 10 * time.Second}, port: port}
	go s.srv.Serve(ln)
	return s, nil
}

func (s *SyncServer) Port() int { return s.port }
func (s *SyncServer) Stop()     { _ = s.srv.Close() }

// PairURL is what Iris for Android opens to pair with this computer.
func PairURL(port int, keyHex, device string) string {
	name, _ := os.Hostname()
	q := url.Values{"h": {lanIP()}, "p": {strconv.Itoa(port)}, "k": {keyHex}, "d": {device}, "n": {name}}
	return "iris://pair?" + q.Encode()
}

// SetPairing shows a "Pair Iris for Android" button on the phone's page
// (pairURL from PairURL; "" takes it away).
func (s *Server) SetPairing(pairURL string) {
	s.mu.Lock()
	s.pair = pairURL
	s.mu.Unlock()
}
