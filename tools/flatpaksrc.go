//go:build ignore

// flatpaksrc lists every Go module Iris builds with as Flatpak sources, for
// a Flathub manifest (which builds without network access):
//
//	go run tools/flatpaksrc.go > packaging/flatpak/go-sources.json
//
// Each module's .info, .mod and .zip come from the Go module proxy with their
// SHA-256 and are laid out as a module proxy in goproxy/, so the build runs
// with GOPROXY=file://$PWD/goproxy and go.sum still checks every module.
package main

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
)

type mod struct {
	Path, Version, Info, GoMod, Zip, Error string
}

type source struct {
	Type     string `json:"type"`
	URL      string `json:"url"`
	SHA256   string `json:"sha256"`
	Dest     string `json:"dest"`
	DestName string `json:"dest-filename"`
}

// escape is the module proxy's spelling of a path: capitals as ! and lower case.
func escape(s string) string {
	var b strings.Builder
	for _, r := range s {
		if r >= 'A' && r <= 'Z' {
			b.WriteByte('!')
			b.WriteRune(r + ('a' - 'A'))
			continue
		}
		b.WriteRune(r)
	}
	return b.String()
}

func sum(path string) string {
	f, err := os.Open(path)
	if err != nil {
		fail(err)
	}
	defer f.Close()
	h := sha256.New()
	io.Copy(h, f)
	return hex.EncodeToString(h.Sum(nil))
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, "flatpaksrc:", err)
	os.Exit(1)
}

func main() {
	out, err := exec.Command("go", "mod", "download", "-json").Output()
	if err != nil {
		fail(err)
	}
	var srcs []source
	dec := json.NewDecoder(bufio.NewReader(bytes.NewReader(out)))
	for dec.More() {
		var m mod
		if err := dec.Decode(&m); err != nil {
			fail(err)
		}
		if m.Error != "" {
			fail(fmt.Errorf("%s@%s: %s", m.Path, m.Version, m.Error))
		}
		esc, ver := escape(m.Path), escape(m.Version)
		dir := "goproxy/" + esc + "/@v"
		for _, f := range []struct{ local, ext string }{{m.Info, ".info"}, {m.GoMod, ".mod"}, {m.Zip, ".zip"}} {
			if f.local == "" {
				continue
			}
			srcs = append(srcs, source{Type: "file", URL: "https://proxy.golang.org/" + esc + "/@v/" + ver + f.ext,
				SHA256: sum(f.local), Dest: dir, DestName: ver + f.ext})
		}
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	if err := enc.Encode(srcs); err != nil {
		fail(err)
	}
}
