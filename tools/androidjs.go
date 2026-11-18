//go:build ignore

// androidjs writes the page scripts Iris uses into the Android app's
// assets, so the Kotlin app runs exactly the same ones:
//
//	go run tools/androidjs.go
package main

import (
	"os"
	"path/filepath"
	"strings"

	"iris/core"
	"iris/shields"
)

func main() {
	dir := filepath.Join("android", "app", "src", "main", "assets", "js")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		panic(err)
	}
	// the fingerprinting script with SEED left for the app to fill in each session
	farble := shields.FarbleScript()
	if i := strings.Index(farble, "let h = "); i >= 0 {
		j := strings.Index(farble[i:], ">>> 0;")
		farble = farble[:i] + "let h = SEED >>> 0;" + farble[i+j+len(">>> 0;"):]
	}
	files := map[string]string{
		"youtube.js":       core.YouTubeScript,
		"youtube-light.js": core.YouTubeLightScript,
		"farble.js":        farble,
		"google-web.js":    core.WebScript,
		"google-images.js": core.ImagesScript,
	}
	for name, js := range files {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(js+"\n"), 0o644); err != nil {
			panic(err)
		}
	}
}
