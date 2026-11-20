//go:build linux && webkit && servo

package main

import (
	"log"

	rules "iris/core/route"
	"iris/core/session"
	"iris/core/session/sqlitestore"
	"iris/webview"
	"iris/webview/route"
	"iris/webview/servo"
)

// newEngine is Servo for light pages and Electron for the rest, sharing one
// cookie store (docs/engines.md).
func newEngine(conf string) webview.Engine {
	var p session.Persister
	if conf != "" {
		if db, err := sqlitestore.Open(conf); err == nil {
			p = db
		} else {
			log.Println("Iris: cookies kept in memory only:", err)
		}
	}
	cookies := session.New(p)
	return route.Wrap(servo.New(cookies), webview.New(), rules.Open(conf))
}
