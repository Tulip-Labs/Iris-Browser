package core

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// Settings are Lite Go's preferences, kept in a small JSON file that loads instantly.
type Settings struct {
	Theme        string   `json:"theme"`
	VerticalTabs bool     `json:"verticalTabs"`
	Mode         Mode     `json:"mode"`
	Shield       bool     `json:"shield"`
	HTTPSOnly    bool     `json:"httpsOnly"`
	YouTube      bool     `json:"youtube"`
	Strict       bool     `json:"strict"`
	Containers   []string `json:"containers"`
	ShieldOff    []string `json:"shieldOff"`
	// Memory is the tab sleep profile: "saver", "balanced" (default) or "speed".
	Memory string `json:"memory"`

	path  string
	mu    sync.Mutex
	timer *time.Timer
}

// LoadSettings reads settings.json from dir ("" = defaults in memory only).
func LoadSettings(dir string) *Settings {
	s := &Settings{Theme: "crocus", Shield: true, HTTPSOnly: true, YouTube: true, Strict: true, Memory: "balanced",
		Containers: []string{"Work", "Personal"}}
	if dir == "" {
		return s
	}
	s.path = filepath.Join(dir, "settings.json")
	if b, err := os.ReadFile(s.path); err == nil {
		_ = json.Unmarshal(b, s)
	}
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
	if os.WriteFile(tmp, b, 0o644) == nil {
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
