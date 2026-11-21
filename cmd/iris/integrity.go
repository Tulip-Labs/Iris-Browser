package main

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
	"os"
	"strings"

	"iris/shell"
)

// sysHooks is what the operating system does for the interface.
func sysHooks() shell.Sys {
	return shell.Sys{Open: openPath, Reveal: revealPath, PickFiles: pickFiles, FreeMB: freeMB, Integrity: integrity}
}

// integrity compares the program file with the SHA-256 recorded beside it
// when Iris was installed or packed ("<program>.sha256"). It tells an
// accident, a bad disk or a careless change; someone able to replace both
// files is not stopped by it.
func integrity() shell.Integrity {
	exe, err := os.Executable()
	if err != nil {
		return shell.IntegrityUnknown
	}
	rec, err := os.ReadFile(exe + ".sha256")
	if err != nil {
		return shell.IntegrityUnknown
	}
	want := strings.ToLower(strings.TrimSpace(string(rec)))
	if i := strings.IndexAny(want, " \t\r\n"); i > 0 {
		want = want[:i]
	}
	f, err := os.Open(exe)
	if err != nil {
		return shell.IntegrityUnknown
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return shell.IntegrityUnknown
	}
	if hex.EncodeToString(h.Sum(nil)) == want {
		return shell.IntegrityVerified
	}
	return shell.IntegrityChanged
}
