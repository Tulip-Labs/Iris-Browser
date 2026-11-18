// Package sqlitestore keeps the shared cookie store (core/session) in
// cookies.sqlite, with the same SQLite as Iris's history.
package sqlitestore

import (
	"database/sql"
	"path/filepath"

	_ "github.com/ncruces/go-sqlite3/driver" // pure-Go SQLite (WebAssembly run by wazero)
	_ "github.com/ncruces/go-sqlite3/embed"

	"iris/core/session"
)

// Store is cookies.sqlite.
type Store struct{ db *sql.DB }

// Open opens (or makes) cookies.sqlite in dir.
func Open(dir string) (*Store, error) {
	db, err := sql.Open("sqlite3", "file:"+filepath.ToSlash(filepath.Join(dir, "cookies.sqlite"))+"?_pragma=journal_mode(WAL)&_pragma=synchronous(NORMAL)")
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	if _, err := db.Exec(`CREATE TABLE IF NOT EXISTS cookies (
		jar TEXT NOT NULL, domain TEXT NOT NULL, path TEXT NOT NULL, name TEXT NOT NULL,
		value TEXT NOT NULL, host_only INTEGER NOT NULL, expires INTEGER NOT NULL,
		secure INTEGER NOT NULL, http_only INTEGER NOT NULL, same_site TEXT NOT NULL,
		PRIMARY KEY (jar, domain, path, name))`); err != nil {
		db.Close()
		return nil, err
	}
	return &Store{db: db}, nil
}

func b2i(b bool) int {
	if b {
		return 1
	}
	return 0
}

// Load reads every kept cookie (session cookies are not kept: they end with
// the browser).
func (s *Store) Load() ([]session.Cookie, error) {
	rows, err := s.db.Query(`SELECT jar, domain, path, name, value, host_only, expires, secure, http_only, same_site FROM cookies`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []session.Cookie
	for rows.Next() {
		var c session.Cookie
		var ho, sec, hon int
		if rows.Scan(&c.Jar, &c.Domain, &c.Path, &c.Name, &c.Value, &ho, &c.Expires, &sec, &hon, &c.SameSite) == nil {
			c.HostOnly, c.Secure, c.HTTPOnly = ho != 0, sec != 0, hon != 0
			out = append(out, c)
		}
	}
	return out, rows.Err()
}

// Put keeps c (a session cookie is kept in memory only).
func (s *Store) Put(c session.Cookie) error {
	if c.Expires == 0 {
		return nil
	}
	_, err := s.db.Exec(`INSERT OR REPLACE INTO cookies VALUES (?,?,?,?,?,?,?,?,?,?)`,
		c.Jar, c.Domain, c.Path, c.Name, c.Value, b2i(c.HostOnly), c.Expires, b2i(c.Secure), b2i(c.HTTPOnly), c.SameSite)
	return err
}

// Delete forgets c.
func (s *Store) Delete(c session.Cookie) error {
	_, err := s.db.Exec(`DELETE FROM cookies WHERE jar=? AND domain=? AND path=? AND name=?`, c.Jar, c.Domain, c.Path, c.Name)
	return err
}

// Clear forgets every cookie of jar.
func (s *Store) Clear(jar string) error {
	_, err := s.db.Exec(`DELETE FROM cookies WHERE jar=?`, jar)
	return err
}

// Close closes the file.
func (s *Store) Close() error { return s.db.Close() }
