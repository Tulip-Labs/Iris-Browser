package core

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// SiteScan is the memory of adaptive shields: what the shield found on each
// site. A site is scanned on its first visits; when several scans in a row
// find nothing to block, the shield stands by there and the site's requests
// go straight to the network. Sites are scanned again now and then, because
// they change.
type SiteScan struct {
	mu    sync.Mutex
	sites map[string]*siteRecord
	path  string
	timer *time.Timer
	now   func() time.Time
}

type siteRecord struct {
	Clean  int   `json:"c"` // scans in a row that found nothing
	Found  int   `json:"f"` // what the last scan blocked or hid
	At     int64 `json:"t"` // when it was last scanned
	Visits int   `json:"v"` // visits since then
}

const (
	scanClean   = 3              // clean scans before the shield stands by
	scanVisits  = 15             // visits before a clean site is scanned again
	scanAge     = 72 * time.Hour // or this long
	scanKeep    = 3000           // sites remembered
	scanDropAge = 90 * 24 * time.Hour
)

// OpenSiteScan loads sites.json from dir ("" = memory only).
func OpenSiteScan(dir string) *SiteScan {
	s := &SiteScan{sites: map[string]*siteRecord{}, now: time.Now}
	if dir == "" {
		return s
	}
	s.path = filepath.Join(dir, "sites.json")
	if b, err := os.ReadFile(s.path); err == nil {
		_ = json.Unmarshal(b, &s.sites)
		for k, r := range s.sites {
			if r == nil {
				delete(s.sites, k)
			}
		}
	}
	return s
}

func scanKey(u string) string { return strings.TrimPrefix(Host(u), "www.") }

// Need says whether the page at u must be checked by the shield: always,
// except on a site found clean that is not due for another scan.
func (s *SiteScan) Need(u string) bool {
	k := scanKey(u)
	if k == "" {
		return true
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	r := s.sites[k]
	return r == nil || r.Clean < scanClean || r.Visits >= scanVisits || s.now().Sub(time.Unix(r.At, 0)) > scanAge
}

// Visit counts a visit to a site that was not scanned this time.
func (s *SiteScan) Visit(u string) {
	s.mu.Lock()
	if r := s.sites[scanKey(u)]; r != nil {
		r.Visits++
		s.saveSoon()
	}
	s.mu.Unlock()
}

// Record keeps the result of a scan: found is how much was blocked or hidden.
func (s *SiteScan) Record(u string, found int) {
	k := scanKey(u)
	if k == "" {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	r := s.sites[k]
	if r == nil {
		r = &siteRecord{}
		s.sites[k] = r
		s.trim()
	}
	if found > 0 {
		r.Clean = 0
	} else {
		r.Clean++
	}
	r.Found, r.At, r.Visits = found, s.now().Unix(), 0
	s.saveSoon()
}

// Forget drops what is known about a site, so it is scanned again.
func (s *SiteScan) Forget(u string) {
	s.mu.Lock()
	delete(s.sites, scanKey(u))
	s.saveSoon()
	s.mu.Unlock()
}

// ScanState is what adaptive shields know about a site.
type ScanState uint8

const (
	ScanNew      ScanState = iota // never scanned
	ScanLearning                  // scanned, not yet enough to decide
	ScanActive                    // it has things to block: the shield stays on
	ScanStandby                   // found clean: the shield stands by
)

// State reports what is known about the site of u, and what the last scan found.
func (s *SiteScan) State(u string) (ScanState, int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	r := s.sites[scanKey(u)]
	switch {
	case r == nil:
		return ScanNew, 0
	case r.Found > 0:
		return ScanActive, r.Found
	case r.Clean >= scanClean:
		return ScanStandby, 0
	}
	return ScanLearning, 0
}

// Counts reports how many sites are remembered and on how many the shield stands by.
func (s *SiteScan) Counts() (sites, standby int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, r := range s.sites {
		if r.Found == 0 && r.Clean >= scanClean {
			standby++
		}
	}
	return len(s.sites), standby
}

// trim forgets the sites scanned longest ago when there are too many (locked).
func (s *SiteScan) trim() {
	if len(s.sites) <= scanKeep {
		return
	}
	type kv struct {
		k  string
		at int64
	}
	all := make([]kv, 0, len(s.sites))
	for k, r := range s.sites {
		all = append(all, kv{k, r.At})
	}
	sort.Slice(all, func(i, j int) bool { return all[i].at < all[j].at })
	old := s.now().Add(-scanDropAge).Unix()
	for i, e := range all {
		if i >= len(all)-scanKeep*9/10 && e.at >= old {
			break
		}
		delete(s.sites, e.k)
	}
}

func (s *SiteScan) saveSoon() {
	if s.path == "" {
		return
	}
	if s.timer != nil {
		s.timer.Stop()
	}
	s.timer = time.AfterFunc(2*time.Second, s.Flush)
}

// Flush writes the file now.
func (s *SiteScan) Flush() {
	if s.path == "" {
		return
	}
	s.mu.Lock()
	b, err := json.Marshal(s.sites)
	s.mu.Unlock()
	if err != nil {
		return
	}
	tmp := s.path + ".tmp"
	if os.WriteFile(tmp, b, 0o644) == nil {
		_ = os.Rename(tmp, s.path)
	}
}
