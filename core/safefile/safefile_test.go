package safefile

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

func TestWriteFile(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "settings.json")
	if err := WriteFile(p, []byte("one"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := WriteFile(p, []byte("two"), 0o600); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(p); string(b) != "two" {
		t.Fatalf("got %q", b)
	}
	if st, _ := os.Stat(p); st.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v", st.Mode().Perm())
	}
	// many writers at once: the file is always one whole content, and no
	// temporary file is left behind
	var wg sync.WaitGroup
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			_ = WriteFile(p, []byte(strings.Repeat(string(rune('a'+i)), 4096)), 0o600)
		}(i)
	}
	wg.Wait()
	b, _ := os.ReadFile(p)
	if len(b) != 4096 || strings.Count(string(b), string(b[0])) != 4096 {
		t.Fatalf("mixed content (%d bytes)", len(b))
	}
	ents, _ := os.ReadDir(dir)
	if len(ents) != 1 {
		t.Fatalf("left behind: %v", ents)
	}
}

func TestWriteFileFails(t *testing.T) {
	if err := WriteFile(filepath.Join(t.TempDir(), "no", "such", "dir", "f"), []byte("x"), 0o600); err == nil {
		t.Fatal("wrote into a missing folder")
	}
}
