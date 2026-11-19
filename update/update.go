// Package update keeps Iris up to date from its GitHub releases.
//
// It asks GitHub for the latest release, picks the file that matches how this
// copy was installed (a .tar.gz in the home folder, a .deb, an .rpm, a
// Flatpak bundle, the Windows installer), checks it against the release's
// SHA256SUMS and installs it. Copies managed by something else (Nix, the
// Microsoft Store, Flathub, the AUR) are left to that.
package update

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Repo is where the releases are published.
const Repo = "Tulip-Labs/Iris-Browser"

// API is GitHub's address (tests point it at a local server).
var API = "https://api.github.com"

// Client is used for every request; downloads get their own longer timeout.
var Client = &http.Client{Timeout: 30 * time.Minute}

// Release is the latest published version.
type Release struct {
	Tag    string  `json:"tag_name"`
	Draft  bool    `json:"draft"`
	Pre    bool    `json:"prerelease"`
	Assets []Asset `json:"assets"`
	URL    string  `json:"html_url"`
}

// Asset is one file of a release.
type Asset struct {
	Name string `json:"name"`
	URL  string `json:"browser_download_url"`
	Size int64  `json:"size"`
}

// Version is the release's version without the leading v.
func (r Release) Version() string { return strings.TrimPrefix(r.Tag, "v") }

func (r Release) asset(name string) (Asset, bool) {
	for _, a := range r.Assets {
		if a.Name == name {
			return a, true
		}
	}
	return Asset{}, false
}

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
	KindFlatpak  Kind = "flatpak"  // Linux: a Flatpak (Flathub or a bundle from the releases)
	KindSnap     Kind = "snap"     // Linux: the Snap
	KindNix      Kind = "nix"      // Linux: Nix
	KindSetup    Kind = "setup"    // Windows: installed by Iris Setup
	KindStore    Kind = "store"    // Windows: the Microsoft Store package
	KindPortable Kind = "portable" // a copy run from wherever it was unpacked
	KindDev      Kind = "dev"      // a build from source
)

// Managed says who updates copies Iris does not update itself. On Linux
// that is every copy: Flatpak, Snap and Nix update Iris.
func (k Kind) Managed() string {
	switch k {
	case KindFlatpak:
		return "Flatpak (Software, or flatpak update)"
	case KindSnap:
		return "Snap (snap refresh)"
	case KindNix:
		return "Nix (nix profile upgrade)"
	case KindStore:
		return "the Microsoft Store"
	case KindPortable:
		return "a new download from the releases page"
	case KindDev:
		return "building again from the source"
	}
	return ""
}

// CanSelf reports whether Iris can install updates for this kind itself.
func (k Kind) CanSelf() bool { return k.Managed() == "" }

// AssetName is the release file for a kind and version.
func AssetName(k Kind, version string) string {
	if k == KindSetup {
		return "Iris-Setup.exe"
	}
	return ""
}

// Fetch downloads the file for kind into dir, checks it against the
// release's SHA256SUMS and returns its path. progress gets 0..1 (may be nil).
func Fetch(ctx context.Context, r Release, k Kind, dir string, progress func(float32)) (string, error) {
	name := AssetName(k, r.Version())
	a, ok := r.asset(name)
	if !ok {
		return "", fmt.Errorf("release %s has no %s", r.Tag, name)
	}
	sums, ok := r.asset("SHA256SUMS")
	if !ok {
		return "", fmt.Errorf("release %s has no SHA256SUMS: not installing an unchecked file", r.Tag)
	}
	want, err := sumFor(ctx, sums.URL, name)
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	path := filepath.Join(dir, name)
	part := path + ".part"
	if err := get(ctx, a.URL, part, a.Size, progress); err != nil {
		os.Remove(part)
		return "", err
	}
	got, err := fileSum(part)
	if err != nil {
		return "", err
	}
	if got != want {
		os.Remove(part)
		return "", fmt.Errorf("%s does not match its checksum: not installing it", name)
	}
	return path, os.Rename(part, path)
}

func sumFor(ctx context.Context, url, name string) (string, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("User-Agent", "Iris-updater")
	res, err := Client.Do(req)
	if err != nil {
		return "", err
	}
	defer res.Body.Close()
	if res.StatusCode != 200 {
		return "", fmt.Errorf("SHA256SUMS: %s", res.Status)
	}
	b, err := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	if err != nil {
		return "", err
	}
	for _, l := range strings.Split(string(b), "\n") {
		f := strings.Fields(l)
		if len(f) >= 2 && strings.TrimPrefix(strings.Join(f[1:], " "), "*") == name && len(f[0]) == 64 {
			return strings.ToLower(f[0]), nil
		}
	}
	return "", fmt.Errorf("SHA256SUMS has no line for %s", name)
}

func get(ctx context.Context, url, path string, size int64, progress func(float32)) error {
	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", "Iris-updater")
	res, err := Client.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if res.StatusCode != 200 {
		return fmt.Errorf("download: %s", res.Status)
	}
	if size <= 0 {
		size = res.ContentLength
	}
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	var n int64
	buf := make([]byte, 256<<10)
	for {
		k, rerr := res.Body.Read(buf)
		if k > 0 {
			if _, err := f.Write(buf[:k]); err != nil {
				f.Close()
				return err
			}
			n += int64(k)
			if progress != nil && size > 0 {
				progress(min(1, float32(n)/float32(size)))
			}
		}
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			f.Close()
			return rerr
		}
	}
	return f.Close()
}

func fileSum(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// Result is what an install did.
type Result struct {
	Version string
	Restart bool // the new version starts with the next launch
}
