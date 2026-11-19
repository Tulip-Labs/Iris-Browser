package sqlitestore

import (
	"testing"

	"iris/core/session"
)

func TestKeeps(t *testing.T) {
	dir := t.TempDir()
	db, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	s := session.New(db)
	s.SetFromHeader("", "https://example.com/", "k=v; Max-Age=3600; Path=/")
	s.SetFromHeader("", "https://example.com/", "sess=1; Path=/") // session cookie: not kept
	db.Close()
	db2, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer db2.Close()
	if h := session.New(db2).Header("", "https://example.com/"); h != "k=v" {
		t.Errorf("after reopening: %q", h)
	}
}
