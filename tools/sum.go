//go:build ignore

// sum writes the SHA-256 of a file beside it, as file.sha256. Iris checks
// its own program file against this record at every start.
//
//	go run tools/sum.go dist/linux/iris
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"log"
	"os"
)

func main() {
	if len(os.Args) != 2 {
		log.Fatal("usage: go run tools/sum.go file")
	}
	b, err := os.ReadFile(os.Args[1])
	if err != nil {
		log.Fatal(err)
	}
	s := sha256.Sum256(b)
	if err := os.WriteFile(os.Args[1]+".sha256", []byte(hex.EncodeToString(s[:])+"\n"), 0o644); err != nil {
		log.Fatal(err)
	}
}
