package core

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Settings are Lite Go's preferences, kept in a small JSON file that loads instantly.
type Settings struct {
	Theme        string      `json:"theme"`
	VerticalTabs bool        `json:"verticalTabs"`
	Mode         Mode        `json:"mode"`
	Shield       bool        `json:"shield"`
	HTTPSOnly    bool        `json:"httpsOnly"`
	YouTube      bool        `json:"youtube"`
	Strict       bool        `json:"strict"`
	Containers   []Container `json:"containers"`
	ShieldOff    []string    `json:"shieldOff"`
	// Memory is the tab sleep profile: "saver", "balanced" (default) or "speed".
	Memory string `json:"memory"`
	// LiteResults shows Google searches on Lite Go's own results page.
	LiteResults bool `json:"liteResults"`
	// YouTubeLight asks YouTube for H.264 video and switches off its glow and previews.
	YouTubeLight bool `json:"youtubeLight"`
	// SiteRanks are the user's choices per site: 1 raise, -1 lower, -2 hide.
	SiteRanks map[string]int `json:"siteRanks"`
	// GoogleSignIn is "" until the first-run sign-in is answered, then "done" or "later".
	GoogleSignIn string `json:"googleSignIn"`
	// Name is what the AI answers call the reader ("" = no name).
	Name string `json:"name,omitempty"`
	// Lite Shields: filter lists (EasyList, EasyPrivacy, uBlock), cookie
	// notices, links without tracking, fingerprinting protection.
	Lists      bool `json:"lists"`
	Cookies    bool `json:"cookies"`
	CleanLinks bool `json:"cleanLinks"`
	Farble     bool `json:"farble"`
	// Boost keeps Lite Go ready in the background so its window opens instantly.
	Boost bool `json:"boost"`
	// Adaptive shields scan a site first and stand by where nothing needs blocking.
	Adaptive bool `json:"adaptive"`
	// Restore reopens the tabs of the last window; Session is what they were.
	// Window is how the reader left the window. Until they change it, Lite Go
	// opens filling the screen.
	Window WindowState `json:"window"`
	// ThemeAt is when the palette was last chosen (sync keeps the newest choice).
	ThemeAt int64 `json:"themeAt,omitempty"`
	// Sync keeps history, open tabs and the palette the same as on a paired phone.
	Sync    SyncSettings `json:"sync"`
	Restore bool         `json:"restore"`
	// AutoUpdate installs new versions from the GitHub releases by itself;
	// UpdateChecked is when it last looked (Unix seconds).
	AutoUpdate    bool         `json:"autoUpdate"`
	UpdateChecked int64        `json:"updateChecked,omitempty"`
	Session       []SessionTab `json:"session,omitempty"`

	path  string
	mu    sync.Mutex
	timer *time.Timer
}

// LoadSettings reads settings.json from dir ("" = defaults in memory only).
func LoadSettings(dir string) *Settings {
	s := &Settings{Theme: "liquid", Shield: true, HTTPSOnly: true, YouTube: true, Strict: false, Memory: "balanced",
		LiteResults: true, Boost: true, YouTubeLight: true,
		Lists: true, Cookies: true, CleanLinks: true, Farble: true,
		Adaptive: true, Restore: true, AutoUpdate: true,
		Containers: []Container{{"Work", "briefcase", "blue"}, {"Personal", "person", "orange"}}}
	if dir == "" {
		return s
	}
	s.path = filepath.Join(dir, "settings.json")
	if b, err := os.ReadFile(s.path); err == nil {
		_ = json.Unmarshal(b, s)
	}
	// The shield has no switches: it blocks everywhere but YouTube, where
	// the ads load and are skipped (core.YouTubeScript)
	s.Shield, s.Lists, s.Cookies, s.CleanLinks, s.YouTube = true, true, true, true, true
	s.ShieldOff = nil
	return s
}

// Save writes the file soon (changes in quick succession are written once).
func (s *Settings) Save() {
	if s.path == "" {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.timer != nil {
		s.timer.Stop()
	}
	s.timer = time.AfterFunc(400*time.Millisecond, s.write)
}

func (s *Settings) write() {
	s.mu.Lock()
	b, err := json.MarshalIndent(s, "", "  ")
	s.mu.Unlock()
	if err != nil {
		return
	}
	tmp := s.path + ".tmp"
	if os.WriteFile(tmp, b, 0o600) == nil {
		_ = os.Rename(tmp, s.path)
	}
}

// Flush writes pending changes now (on exit).
func (s *Settings) Flush() {
	if s.path == "" {
		return
	}
	s.mu.Lock()
	if s.timer != nil {
		s.timer.Stop()
	}
	s.mu.Unlock()
	s.write()
}

// WindowState is the window's size (in the interface's units) and whether
// the reader took it out of the maximized state.
type WindowState struct {
	W, H     int
	Windowed bool
}

// SetWindow records how the window is now, and reports whether that is news.
func (s *Settings) SetWindow(windowed bool, w, h int) bool {
	n := s.Window
	n.Windowed = windowed
	if windowed && w >= 480 && h >= 420 {
		n.W, n.H = w, h
	}
	if n == s.Window {
		return false
	}
	s.Window = n
	s.Save()
	return true
}

// SyncSettings is this computer's side of the sync with Lite for Android.
type SyncSettings struct {
	On     bool   `json:"on"`
	Key    string `json:"key,omitempty"`    // shared with the paired devices; never leaves the local network
	Device string `json:"device,omitempty"` // this computer's id
	Peers  []Peer `json:"peers,omitempty"`
}

// Peer is a paired device, as it was at the last sync.
type Peer struct {
	ID   string       `json:"id"`
	Name string       `json:"name"`
	Seen int64        `json:"seen"`
	Tabs []SessionTab `json:"tabs,omitempty"`
}

// SessionTab is a tab kept for the next window.
type SessionTab struct {
	URL       string `json:"url"`
	Title     string `json:"title,omitempty"`
	Container string `json:"container,omitempty"`
	Active    bool   `json:"active,omitempty"`
}

// Container is a named set of sign-ins with its own icon and color.
type Container struct {
	Name  string `json:"name"`
	Icon  string `json:"icon"`
	Color string `json:"color"`
}

// ContainerIcons and ContainerColors are the choices offered for containers.
var (
	ContainerIcons  = []string{"briefcase", "person", "cart", "dollar", "heart", "star", "book", "code", "gamepad", "home", "globe", "lab"}
	ContainerColors = []string{"blue", "turquoise", "green", "yellow", "orange", "red", "pink", "purple"}
)

// UnmarshalJSON also reads the first format, where a container was only its name.
func (c *Container) UnmarshalJSON(b []byte) error {
	var name string
	if json.Unmarshal(b, &name) == nil {
		*c = Container{Name: name, Icon: "briefcase", Color: "blue"}
		return nil
	}
	type plain Container
	return json.Unmarshal(b, (*plain)(c))
}

// FindContainer returns the container named name (case does not matter).
func (s *Settings) FindContainer(name string) (Container, bool) {
	for _, c := range s.Containers {
		if strings.EqualFold(c.Name, name) {
			return c, true
		}
	}
	return Container{Name: name, Icon: "briefcase", Color: "blue"}, false
}
