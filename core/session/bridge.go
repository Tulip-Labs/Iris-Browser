package session

import "sort"

// The cookie bridge: on Linux two engines draw pages (WebKitGTK and
// Electron), each with its own cookie jar. Each reports every cookie it
// sets or removes here (Report), and the store hands the change to the other
// engines (Watch), so a sign-in in one engine is a sign-in in both. A change
// an engine reports back after the store gave it to it is the same cookie
// and goes no further, so nothing echoes.

// Watcher receives a cookie change from another engine.
type Watcher func(c Cookie, removed bool)

type watcher struct {
	src string
	f   Watcher
}

// Watch registers engine src: it is told of every change the other engines
// report. f may be called on any goroutine.
func (s *Store) Watch(src string, f Watcher) {
	s.mu.Lock()
	s.watchers = append(s.watchers, watcher{src, f})
	s.mu.Unlock()
}

// same says whether two cookies carry the same thing for the engines (the
// engines round expiry times, and spell an unset SameSite their own way).
func same(a, b *Cookie) bool {
	d := a.Expires - b.Expires
	if d < 0 {
		d = -d
	}
	return a.Value == b.Value && a.HostOnly == b.HostOnly && a.Secure == b.Secure && a.HTTPOnly == b.HTTPOnly &&
		(a.Expires == 0) == (b.Expires == 0) && d <= 2
}

// Report is a cookie engine src set (or removed) in its jar c.Jar. It is
// stored and, when it changes anything, given to the other engines. It
// reports whether it changed anything.
func (s *Store) Report(src string, c Cookie, removed bool) bool {
	if c.Name == "" || c.Domain == "" {
		return false
	}
	if c.Path == "" {
		c.Path = "/"
	}
	k := c.key()
	s.mu.Lock()
	old, had := s.all[k]
	switch {
	case removed && !had:
		s.mu.Unlock()
		return false
	case !removed && had && same(old, &c):
		s.mu.Unlock()
		return false
	}
	if removed {
		delete(s.all, k)
		if s.disk != nil && !Memory(c.Jar) {
			s.disk.Delete(*old)
		}
	} else {
		cc := c
		s.all[k] = &cc
		if s.disk != nil && !Memory(c.Jar) {
			s.disk.Put(cc)
		}
	}
	ws := append([]watcher(nil), s.watchers...)
	s.mu.Unlock()
	for _, w := range ws {
		if w.src != src {
			w.f(c, removed)
		}
	}
	return true
}

// Jar is every live cookie of jar (an engine starting a session loads them).
func (s *Store) Jar(jar string) []Cookie {
	now := s.now().Unix()
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []Cookie
	for _, c := range s.all {
		if c.Jar == jar && (c.Expires == 0 || c.Expires > now) {
			out = append(out, *c)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].key() < out[j].key() })
	return out
}

// Diff compares what an engine holds in a jar now (cur) with what it held
// before (was, keyed by Key) and reports each difference as engine src.
// It returns cur keyed for the next call.
func (s *Store) Diff(src string, was map[string]Cookie, cur []Cookie) map[string]Cookie {
	next := make(map[string]Cookie, len(cur))
	for _, c := range cur {
		if c.Path == "" {
			c.Path = "/"
		}
		k := c.key()
		next[k] = c
		if o, ok := was[k]; !ok || !same(&o, &c) {
			s.Report(src, c, false)
		}
	}
	for k, o := range was {
		if _, ok := next[k]; !ok {
			s.Report(src, o, true)
		}
	}
	return next
}

// Key identifies a cookie within the store (jar, domain, path and name).
func (c *Cookie) Key() string { return c.key() }
