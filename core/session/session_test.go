package session

import (
	"strings"
	"testing"
	"time"
)

type memDisk struct{ m map[string]Cookie }

func (d *memDisk) Load() ([]Cookie, error) {
	var out []Cookie
	for _, c := range d.m {
		out = append(out, c)
	}
	return out, nil
}
func (d *memDisk) Put(c Cookie) error    { d.m[c.key()] = c; return nil }
func (d *memDisk) Delete(c Cookie) error { delete(d.m, c.key()); return nil }
func (d *memDisk) Clear(jar string) error {
	for k, c := range d.m {
		if c.Jar == jar {
			delete(d.m, k)
		}
	}
	return nil
}

func TestSharedAcrossEngines(t *testing.T) {
	disk := &memDisk{m: map[string]Cookie{}}
	s := New(disk)
	now := time.Unix(1_800_000_000, 0)
	s.now = func() time.Time { return now }
	// Google's sign-in (heavy engine) sets a cookie for the whole domain
	if !s.SetFromHeader("", "https://accounts.google.com/signin", "SID=abc; Domain=.google.com; Path=/; Secure; HttpOnly; Max-Age=3600") {
		t.Fatal("not taken")
	}
	// the search page (Servo) gets it
	if h := s.Header("", "https://www.google.com/search?q=x"); h != "SID=abc" {
		t.Errorf("header %q", h)
	}
	// not over plain http, not for another site, not in a container
	if s.Header("", "http://www.google.com/") != "" || s.Header("", "https://example.com/") != "" || s.Header("c-work", "https://www.google.com/") != "" {
		t.Error("cookie leaked")
	}
	// kept on disk, and back after a restart
	s2 := New(disk)
	s2.now = s.now
	if s2.Header("", "https://mail.google.com/") != "SID=abc" {
		t.Error("not kept")
	}
	// expiry
	now = now.Add(2 * time.Hour)
	if s2.Header("", "https://www.google.com/") != "" || len(disk.m) != 0 {
		t.Error("expired cookie still there")
	}
}

func TestRules(t *testing.T) {
	s := New(nil)
	// host-only, default path
	s.SetFromHeader("", "https://a.example.com/docs/page", "h=1")
	if s.Header("", "https://a.example.com/docs/other") != "h=1" || s.Header("", "https://b.example.com/docs/x") != "" || s.Header("", "https://a.example.com/") != "" {
		t.Error("host-only or default path")
	}
	// a site cannot set cookies for another
	if s.SetFromHeader("", "https://evil.com/", "x=1; Domain=example.com") {
		t.Error("cross-site cookie taken")
	}
	// longer paths first
	s.SetFromHeader("", "https://example.com/", "a=1; Path=/")
	s.SetFromHeader("", "https://example.com/", "b=2; Path=/x")
	if h := s.Header("", "https://example.com/x/y"); h != "b=2; a=1" {
		t.Errorf("order %q", h)
	}
	// deleting with Max-Age=0 or a past date
	s.SetFromHeader("", "https://example.com/", "a=; Path=/; Max-Age=-1")
	if strings.Contains(s.Header("", "https://example.com/"), "a=") {
		t.Error("not deleted")
	}
	// private jars never reach the disk
	disk := &memDisk{m: map[string]Cookie{}}
	p := New(disk)
	p.SetFromHeader("private-1", "https://example.com/", "p=1")
	if len(disk.m) != 0 || p.Header("private-1", "https://example.com/") != "p=1" {
		t.Error("private jar")
	}
	p.Clear("private-1")
	if p.Header("private-1", "https://example.com/") != "" {
		t.Error("clear")
	}
	// the Set-Cookie line an engine is given back holds the same cookie
	c := s.For("", "https://example.com/x/y")[0]
	s3 := New(nil)
	s3.SetFromHeader("", "https://example.com/x/", c.SetCookie())
	if s3.Header("", "https://example.com/x/y") != "b=2" {
		t.Errorf("round trip %q", c.SetCookie())
	}
}
