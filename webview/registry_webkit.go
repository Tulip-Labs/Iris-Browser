//go:build (linux && webkit) || windows

package webview

import (
	"strings"
	"sync"
)

// The WebKit engine keeps its views in a table: the native
// side reports events with a view's number, and Go finds the view here.

type wkView struct {
	id      uintptr
	native  uintptr // the platform's view handle
	ev      Events
	url     string
	closed  bool
	private bool
	sandbox bool
}

var (
	wkMu    sync.Mutex
	wkViews = map[uintptr]*wkView{}
	wkNext  uintptr
	wkEng   *wkEngine
)

// popupImpl is a pending pop-up: Electron's (native, id) or WebKit's page
// (kit), made by the page that opened it.
type popupImpl struct{ native, id, kit uintptr }

func (i popupImpl) kitPage() bool { return i.kit != 0 }

func wkAdd(v *wkView) uintptr {
	wkMu.Lock()
	defer wkMu.Unlock()
	wkNext++
	v.id = wkNext
	wkViews[v.id] = v
	return v.id
}

func wkGet(id uintptr) *wkView {
	wkMu.Lock()
	defer wkMu.Unlock()
	return wkViews[id]
}

func wkDel(id uintptr) {
	wkMu.Lock()
	delete(wkViews, id)
	wkMu.Unlock()
}

// the policy decisions of the WebKit engine

type wkEngine struct {
	mu      sync.Mutex
	policy  Policy
	dataDir string
	low     bool
	started bool
}

// decide returns the address to open instead of u ("" to open u as is), or
// "-" to stop it (HTTPS-only, or a page that looks unsafe).
func (e *wkEngine) decide(v *wkView, u string) string {
	e.mu.Lock()
	p := e.policy
	e.mu.Unlock()
	if p.Rewrite != nil {
		if c := p.Rewrite(u); c != "" && c != u {
			return c
		}
	}
	if v.sandbox {
		return "" // a sandbox is where an unsafe page may open
	}
	stop := p.HTTPSOnly && strings.HasPrefix(strings.ToLower(u), "http://") && (p.AllowInsecure == nil || !p.AllowInsecure(u))
	if !stop && p.Unsafe != nil {
		stop = p.Unsafe(u)
	}
	if stop {
		if v.ev.Insecure != nil {
			v.ev.Insecure(u)
		}
		return "-"
	}
	return ""
}

// vkFromChar maps a typed character to a Windows virtual key (the code the
// shortcut table uses).
func vkFromChar(c rune) uint32 {
	switch {
	case c >= 'a' && c <= 'z':
		return uint32(c - 'a' + 'A')
	case c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
		return uint32(c)
	case c == ',':
		return 0xBC
	case c == '+', c == '=':
		return 0xBB
	case c == '-':
		return 0xBD
	case c == '\t':
		return 0x09
	}
	return 0
}
