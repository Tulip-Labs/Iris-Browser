//go:build linux && webkit

package main

import (
	"log"

	rules "iris/core/route"
	"iris/core/session"
	"iris/core/session/sqlitestore"
	"iris/webview"
	"iris/webview/route"
)

// newEngine is WebKitGTK for most pages and Electron for the heavy ones
// (video, social sites, web apps), sharing one cookie store: a sign-in in
// one engine is a sign-in in the other (docs/engines.md).
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
	webview.SetCookies(cookies)
	return route.Wrap(webview.NewWebKit(cookies), webview.New(), rules.Open(conf))
}
