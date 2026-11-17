package shell

import (
	"litego/ui"
	"litego/webview"
)

type action uint8

const (
	actNone action = iota
	actNewTab
	actPrivate
	actTemp
	actClose
	actReopen
	actAddress
	actNext
	actPrev
	actReload
	actBack
	actForward
	actFullscreen
	actSettings
	actKinds
	actMute
	actAI
	actFind
	actPrint
	actHistory
	actDownloads
	actSplit
	actFree
	actZoomIn
	actZoomOut
	actZoomReset
	actTab1 // actTab1+n selects tab n+1; the last one is actTab9 (last tab)
)

const actTab9 = actTab1 + 8

// vkAction maps a key pressed inside the page (a Windows virtual key) to a browser action.
func vkAction(k webview.Key) action {
	vk := k.VK
	switch {
	case k.Ctrl && !k.Alt:
		switch {
		case vk == 'T' && k.Shift:
			return actReopen
		case vk == 'T':
			return actNewTab
		case vk == 'N' && k.Shift:
			return actPrivate
		case vk == 'W', vk == 0x73: // Ctrl+F4
			return actClose
		case vk == 'L', vk == 'K':
			return actAddress
		case vk == 0x09 && k.Shift, vk == 0x21: // Ctrl+Shift+Tab, Ctrl+PageUp
			return actPrev
		case vk == 0x09, vk == 0x22:
			return actNext
		case vk == 'R':
			return actReload
		case vk == 'F':
			return actFind
		case vk == 'P':
			return actPrint
		case vk == 'H':
			return actHistory
		case vk == 'S' && k.Shift:
			return actSplit
		case vk == 'D' && k.Shift:
			return actDownloads
		case vk == 0xBB, vk == 0x6B: // Ctrl+plus
			return actZoomIn
		case vk == 0xBD, vk == 0x6D:
			return actZoomOut
		case vk == '0', vk == 0x60:
			return actZoomReset
		case vk >= '1' && vk <= '9':
			return actTab1 + action(vk-'1')
		case vk == 0xBC: // Ctrl+,
			return actSettings
		case vk == 'M':
			return actMute
		case vk == 'J':
			return actAI
		}
	case k.Alt && !k.Ctrl:
		switch vk {
		case 0x25:
			return actBack
		case 0x27:
			return actForward
		case 'D':
			return actAddress
		}
	case !k.Ctrl && !k.Alt:
		switch vk {
		case 0x74: // F5
			return actReload
		case 0x75: // F6
			return actAddress
		case 0x7A: // F11
			return actFullscreen
		case 0xA6: // browser back key
			return actBack
		case 0xA7:
			return actForward
		}
	}
	return actNone
}

var digitKeys = []ui.Key{ui.K1, ui.K2, ui.K3, ui.K4, ui.K5, ui.K6, ui.K7, ui.K8, ui.K9}

// keyAction maps a key pressed in the interface to a browser action.
func keyAction(k ui.KeyPress) action {
	switch {
	case k.Ctrl && !k.Alt:
		switch k.Key {
		case ui.KT:
			if k.Shift {
				return actReopen
			}
			return actNewTab
		case ui.KN:
			if k.Shift {
				return actPrivate
			}
		case ui.KW:
			return actClose
		case ui.KL, ui.KK:
			return actAddress
		case ui.KTab:
			if k.Shift {
				return actPrev
			}
			return actNext
		case ui.KPageUp:
			return actPrev
		case ui.KPageDown:
			return actNext
		case ui.KR:
			return actReload
		case ui.KF:
			return actFind
		case ui.KP:
			return actPrint
		case ui.KH:
			return actHistory
		case ui.KS:
			if k.Shift {
				return actSplit
			}
		case ui.KD:
			if k.Shift {
				return actDownloads
			}
		case ui.KPlus:
			return actZoomIn
		case ui.KMinus:
			return actZoomOut
		case ui.KZero:
			return actZoomReset
		case ui.KComma:
			return actSettings
		case ui.KM:
			return actMute
		case ui.KJ:
			return actAI
		}
		for i, d := range digitKeys {
			if k.Key == d {
				return actTab1 + action(i)
			}
		}
	case k.Alt && !k.Ctrl:
		switch k.Key {
		case ui.KLeft:
			return actBack
		case ui.KRight:
			return actForward
		case ui.KD:
			return actAddress
		}
	case !k.Ctrl && !k.Alt:
		switch k.Key {
		case ui.KF5:
			return actReload
		case ui.KF6:
			return actAddress
		case ui.KF11:
			return actFullscreen
		}
	}
	return actNone
}

// shortcuts runs the browser shortcuts typed in the interface.
func (a *App) shortcuts() {
	in := a.In
	rest := in.Keys[:0]
	var acts []action
	for _, k := range in.Keys {
		if act := keyAction(k); act != actNone {
			acts = append(acts, act)
			continue
		}
		rest = append(rest, k)
	}
	in.Keys = rest
	for _, act := range acts {
		a.do(act)
	}
}

func (a *App) do(act action) {
	t := a.tab()
	switch {
	case act == actNewTab:
		a.newTab(KNormal, "", "", true)
	case act == actPrivate:
		a.newTab(KPrivate, "", "", true)
	case act == actTemp:
		a.newTab(KTemp, "", "", true)
	case act == actClose:
		a.closeTab(a.cur)
	case act == actReopen:
		a.reopen()
	case act == actAddress:
		a.focusAddress()
	case act == actNext:
		a.selectTab((a.cur + 1) % len(a.tabs))
	case act == actPrev:
		a.selectTab((a.cur + len(a.tabs) - 1) % len(a.tabs))
	case act == actTab9:
		a.selectTab(len(a.tabs) - 1)
	case act >= actTab1 && act < actTab9:
		a.selectTab(int(act - actTab1))
	case act == actSettings:
		a.togglePanel(panelSettings)
	case act == actKinds:
		a.kindOpen = !a.kindOpen
	case act == actFree:
		a.FreeMemory()
	case act == actHistory:
		a.togglePanel(panelHistory)
	case act == actDownloads:
		a.togglePanel(panelDownloads)
	case act == actSplit:
		a.toggleSplit()
	case act == actFind:
		a.openFind()
	case act == actPrint:
		if t != nil && t.view != nil && t.search == nil && t.URL != "" {
			v := t.view
			a.web(func() { v.Eval("window.print()") })
		} else {
			a.notify("Open a page to print it.")
		}
	case act == actZoomIn:
		a.zoomBy(t, 1)
	case act == actZoomOut:
		a.zoomBy(t, -1)
	case act == actZoomReset:
		a.zoomBy(t, 0)
	case act == actAI:
		if a.ai.open {
			a.ai.open = false
		} else {
			a.openAI("")
		}
	case act == actFullscreen:
		a.winFull = !a.winFull
		a.h.SetFullscreen(a.winFull || a.full)
	case t == nil:
	case act == actReload:
		a.reload(t)
	case act == actBack:
		a.back(t)
	case act == actForward:
		a.forward(t)
	case act == actMute:
		a.toggleMute(t)
	}
}

func (a *App) reload(t *Tab) {
	if t.URL == "" {
		return
	}
	if s := t.search; s != nil {
		n := a.startSearch(s.Q, s.Mode, s.URL, t.private())
		n.aiOpen = s.aiOpen
		t.search = n
		return
	}
	if t.Crashed || t.view == nil {
		a.unload(t)
		t.Crashed = false
		t.pending = t.URL
		t.Loading = true
		a.ensureView(t)
		return
	}
	v := t.view
	t.Loading = true
	a.web(v.Reload)
}

func (a *App) toggleMute(t *Tab) {
	t.Muted = !t.Muted
	if v := t.view; v != nil {
		m := t.Muted
		a.web(func() { v.SetMuted(m) })
	}
}

// focusAddress gives the keyboard to the address bar (from the page too).
func (a *App) focusAddress() {
	t := a.tab()
	if t != nil && t.URL == "" && !a.Fullscreen() {
		a.st.Focus = ID("ntp")
	} else {
		a.st.Focus = ID("addr")
		if t != nil {
			a.addr.Set(t.addrText())
		}
		a.addr.SelectAll()
	}
	h := a.h
	a.web(h.FocusWindow)
}
