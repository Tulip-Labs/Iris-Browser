//go:build ignore

// gz compresses a file for the setup to embed: go run tools/gz.go in out
package main

import (
	"compress/gzip"
	"io"
	"log"
	"os"
)

func main() {
	if len(os.Args) != 3 {
		log.Fatal("usage: go run tools/gz.go in out")
	}
	in, err := os.Open(os.Args[1])
	if err != nil {
		log.Fatal(err)
	}
	defer in.Close()
	out, err := os.Create(os.Args[2])
	if err != nil {
		log.Fatal(err)
	}
	zw, _ := gzip.NewWriterLevel(out, gzip.BestCompression)
	if _, err := io.Copy(zw, in); err != nil {
		log.Fatal(err)
	}
	if err := zw.Close(); err != nil {
		log.Fatal(err)
	}
	if err := out.Close(); err != nil {
		log.Fatal(err)
	}
}
