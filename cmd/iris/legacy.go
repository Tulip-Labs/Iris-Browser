package main

import (
	"os"
	"strings"
)

// Iris was called Lite Go until 1.0.19. What that name left behind is taken
// over here: its LITEGO_* settings in the environment, and its folders.

func init() {
	for _, kv := range os.Environ() {
		k, v, ok := strings.Cut(kv, "=")
		if !ok || !strings.HasPrefix(k, "LITEGO_") {
			continue
		}
		if n := "IRIS_" + strings.TrimPrefix(k, "LITEGO_"); os.Getenv(n) == "" {
			os.Setenv(n, v)
		}
	}
}
