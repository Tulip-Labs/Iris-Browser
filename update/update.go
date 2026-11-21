// Package update tells whether a newer Iris is out: it asks GitHub for the
// latest release. Iris never replaces itself; Flatpak, Snap or Nix, which
// installed it, bring the new version.
package update

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// Repo is where the releases are published.
const Repo = "Tulip-Labs/Iris-Browser"

// API is GitHub's address (tests point it at a local server).
var API = "https://api.github.com"

// Client asks GitHub.
var Client = &http.Client{Timeout: 30 * time.Second}

// Release is the latest published version.
type Release struct {
	Tag   string `json:"tag_name"`
	Draft bool   `json:"draft"`
	Pre   bool   `json:"prerelease"`
	URL   string `json:"html_url"`
}

// Version is the release's version without the leading v.
func (r Release) Version() string { return strings.TrimPrefix(r.Tag, "v") }

// Latest asks GitHub for the newest release.
func Latest(ctx context.Context) (Release, error) {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, "GET", API+"/repos/"+Repo+"/releases/latest", nil)
	if err != nil {
		return Release{}, err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", "Iris-updater")
	res, err := Client.Do(req)
	if err != nil {
		return Release{}, err
	}
	defer res.Body.Close()
	if res.StatusCode != 200 {
		return Release{}, fmt.Errorf("GitHub answered %s", res.Status)
	}
	var r Release
	if err := json.NewDecoder(io.LimitReader(res.Body, 4<<20)).Decode(&r); err != nil {
		return Release{}, err
	}
	if r.Tag == "" {
		return Release{}, errors.New("the release has no version")
	}
	return r, nil
}

// Newer reports whether version a is newer than b ("1.0.10" > "1.0.9").
func Newer(a, b string) bool {
	pa, pb := parts(a), parts(b)
	for i := 0; i < max(len(pa), len(pb)); i++ {
		var x, y int
		if i < len(pa) {
			x = pa[i]
		}
		if i < len(pb) {
			y = pb[i]
		}
		if x != y {
			return x > y
		}
	}
	return false
}

func parts(v string) []int {
	v = strings.TrimPrefix(strings.TrimSpace(v), "v")
	if i := strings.IndexAny(v, "-+ "); i >= 0 {
		v = v[:i]
	}
	var out []int
	for _, p := range strings.Split(v, ".") {
		n, _ := strconv.Atoi(p)
		out = append(out, n)
	}
	return out
}

// Kind is how this copy was installed.
type Kind string

const (
	KindFlatpak Kind = "flatpak" // Linux: a Flatpak (Flathub or a bundle from the releases)
	KindSnap    Kind = "snap"    // Linux: the Snap
	KindNix     Kind = "nix"     // Linux: Nix
	KindDev     Kind = "dev"     // a build from source
)

// Managed says what brings this copy its updates.
func (k Kind) Managed() string {
	switch k {
	case KindFlatpak:
		return "Flatpak (Software, or flatpak update)"
	case KindSnap:
		return "Snap (snap refresh)"
	case KindNix:
		return "Nix (nix profile upgrade)"
	case KindDev:
		return "building again from the source"
	}
	return ""
}
