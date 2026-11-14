package shell

import (
	"strconv"
	"strings"

	"litego/core"
	"litego/ui"
)

// The settings page: a tab of its own, like chrome://settings, with the
// sections in a column at the left and the chosen one at the right.

type settingsSection struct {
	id, label, tip string
	icon           ui.Icon
}

var settingsSections = []settingsSection{
	{"look", "Appearance", "Palette and where the tabs go", ui.IPalette},
	{"search", "Search", "Search mode, Lite results and Google sign-in", ui.ISearch},
	{"shields", "Shields and privacy", "Ads, trackers, cookie notices and fingerprinting", ui.IShield},
	{"containers", "Containers", "Separate sign-ins: their names, icons and colors", ui.IContainer},
	{"memory", "Performance", "Memory plan and the balancer", ui.IMemory2},
	{"phone", "Phone and sync", "Move files by QR code; sync with Lite for Android", ui.IPhone},
	{"startup", "On startup", "Staying ready in the background", ui.IHome},
	{"data", "History and data", "Reopening tabs and clearing history", ui.IHistory},
	{"about", "About Lite Go", "Version, integrity and license", ui.IInfo},
}

// openSettings shows the settings page (in the tab that already has it, or
// a new one) at section sec ("" keeps the last one).
func (a *App) openSettings(sec string) {
	a.panel = false
	if sec != "" {
		a.setSec = sec
	}
	if a.setSec == "" {
		a.setSec = "look"
	}
	for i, t := range a.tabs {
		if t.settings {
			a.selectTab(i)
			return
		}
	}
	t := a.newTab(KNormal, "", "", true)
	if t.view != nil { // a spare page made for a new tab: not needed here
		a.unload(t)
	}
	t.settings, t.Title = true, "Settings"
	a.st.Focus = ui.ID{}
}

func (a *App) settingsPage(r ui.Rect) {
	u, g, th := &a.u, a.u.G, a.u.Th
	fillPage(g, r, 14, th)
	narrow := r.W < 760
	navW := float32(244)
	if narrow {
		navW = 64
	}
	nav := ui.Rect{X: r.X + 12, Y: r.Y + 12, W: navW, H: r.H - 24}
	y := nav.Y
	if !narrow {
		g.Text("Settings", nav.X+12, y+28, ui.FBig, th.OnSurface)
		y += 52
	}
	for _, s := range settingsSections {
		row := ui.Rect{X: nav.X, Y: y, W: nav.W, H: 42}
		on := s.id == a.setSec
		switch {
		case on:
			ui.FillRound(g, row, 21, th.Primary.Alpha(0.16))
		case u.Hover(row):
			ui.FillRound(g, row, 21, th.Ink.Alpha(0.06))
		}
		col := th.OnSurfaceVariant
		if on {
			col = th.Primary
		}
		if narrow {
			ui.DrawIcon(g, s.icon, row.CX()-10, row.CY()-10, 20, col)
			u.Tooltip(s.label, row)
		} else {
			ui.DrawIcon(g, s.icon, row.X+16, row.CY()-10, 20, col)
			f := ui.FBody
			if on {
				f = ui.FBodyBold
			}
			ui.TextFit(g, s.label, row.X+48, ui.Mid(g, row.Y, row.H, f), f, th.OnSurface, row.W-56)
		}
		if u.Clickable(ui.Id("setnav/"+s.id), row) && !on {
			a.setSec, a.setSc = s.id, ui.Scroll{}
		}
		y += 46
	}

	// the chosen section, in a card no wider than a comfortable line
	area := ui.Rect{X: nav.R() + 16, Y: r.Y + 12, W: r.R() - nav.R() - 28, H: r.H - 24}
	cw := min(area.W, 760)
	card := ui.Rect{X: area.X + (area.W-cw)/2, Y: area.Y, W: cw, H: area.H}
	ui.Glass(g, card, 22, th, true, false)
	body := card.Inset(4)
	if a.setSec == "phone" {
		a.drawPhone(body) // it scrolls by itself
		return
	}
	sc := &a.setSc
	u.Scroll(ID("setsc"), body, sc)
	g.Save()
	g.Clip(body)
	u.PushHit(body)
	top := body.Y + 10 - sc.Y
	var end float32
	if a.setSec == "containers" {
		end = a.containerSettings(body.X+24, top, body.W-48)
	} else {
		end = a.settingsBody(body.X+24, top, body.W-48, a.setSec)
	}
	sc.Content = end + sc.Y - body.Y + 16
	u.PopHit()
	g.Restore()
}

// containerSettings lists the containers with their editor, and adds new ones.
func (a *App) containerSettings(x, y, w float32) float32 {
	u, g, th := &a.u, a.u.G, a.u.Th
	y += 10
	g.Text("Containers", x, y+16, ui.FTitle, th.OnSurface)
	y += 34
	for _, ln := range wrap(g, "Each container keeps its own sign-ins, cookies and site data, apart from your other tabs: a work account and a personal one side by side. Open a tab in one from the menu of the + button beside the tabs (or right-click it).", ui.FSmall, w) {
		g.Text(ln, x, y+14, ui.FSmall, th.OnSurfaceVariant)
		y += 18
	}
	y += 12
	for i, c := range a.set.Containers {
		if i == a.editCont {
			y += a.containerEditor(ui.Rect{X: x, Y: y, W: w}, i) + 10
			continue
		}
		row := ui.Rect{X: x, Y: y, W: w, H: 52}
		ui.FillRound(g, row, 16, th.SurfaceHigh)
		col := tone(th, c.Color)
		ui.FillRound(g, ui.Rect{X: row.X + 12, Y: row.CY() - 15, W: 30, H: 30}, 10, col)
		ui.DrawIcon(g, iconOf(c), row.X+18, row.CY()-9, 18, ui.White)
		ui.TextFit(g, c.Name, row.X+54, ui.Mid(g, row.Y, row.H, ui.FBodyBold), ui.FBodyBold, th.OnSurface, row.W-180)
		n := 0
		for _, t := range a.tabs {
			if t.Kind == KContainer && t.Container == c.Name {
				n++
			}
		}
		if n > 0 {
			s := "1 tab open"
			if n > 1 {
				s = strconv.Itoa(n) + " tabs open"
			}
			g.Text(s, row.R()-170, ui.Mid(g, row.Y, row.H, ui.FSmall), ui.FSmall, th.OnSurfaceVariant)
		}
		if u.IconButton(ui.IdN("contopen", i), ui.Rect{X: row.R() - 84, Y: row.CY() - 18, W: 36, H: 36}, ui.IPlus, "New tab in "+c.Name, ui.IconOpt{}) {
			a.newTab(KContainer, c.Name, "", true)
		}
		if u.IconButton(ui.IdN("contedit", i), ui.Rect{X: row.R() - 44, Y: row.CY() - 18, W: 36, H: 36}, ui.IEdit, "Name, icon and color", ui.IconOpt{}) {
			a.editCont = i
			a.contName.Set(c.Name)
		}
		y += 60
	}
	y += 6
	fr := ui.Rect{X: x, Y: y, W: w - 100, H: 40}
	add := func() {
		name := strings.TrimSpace(a.newCont.Text())
		if name == "" {
			return
		}
		if _, taken := a.set.FindContainer(name); taken {
			a.notify("There is already a container named " + name + ".")
			return
		}
		n := len(a.set.Containers)
		a.set.Containers = append(a.set.Containers, core.Container{Name: name,
			Icon: core.ContainerIcons[(n+2)%len(core.ContainerIcons)], Color: core.ContainerColors[(n*3+1)%len(core.ContainerColors)]})
		a.set.Save()
		a.newCont.Set("")
		a.editCont = n
		a.contName.Set(name)
	}
	u.TextField(ID("setcontname"), fr, a.newCont, ui.FieldOpt{Placeholder: "New container: Work, Shopping…", OnEnter: add})
	if u.Button(ID("setcontadd"), ui.Rect{X: fr.R() + 8, Y: fr.Y + 2, W: 92, H: 36}, "Add", ui.ButtonOpt{Primary: true, Icon: ui.IPlus, HasIcon: true}) {
		add()
	}
	return y + 56
}

// ---- the new tab menu: what kind of tab to open (the + button's menu) ----

// kindMenu is the row under the toolbar that opens a tab of a chosen kind;
// it pushes the page down rather than covering it (pages are native windows).
func (a *App) kindMenu(r ui.Rect) {
	u, g, th := &a.u, a.u.G, a.u.Th
	ui.Glass(g, r, 18, th, true, false)
	type item struct {
		label, tip string
		icon       ui.Icon
		col        ui.Color
		open       func()
	}
	items := []item{
		{"New tab", "Ctrl+T", ui.IHome, th.Primary, func() { a.newTab(KNormal, "", "", true) }},
		{"Private", "Nothing is kept  Ctrl+Shift+N", ui.IPrivate, privateColor(th), func() { a.newTab(KPrivate, "", "", true) }},
		{"Temporary", "A fresh session for this tab alone, wiped when it closes", ui.IHourglass, ui.Mix(th.Hl, th.Ink, 0.25), func() { a.newTab(KTemp, "", "", true) }},
		{"Sandbox", "For a site you do not trust: no downloads, no permissions, nothing kept", ui.IShield, sandboxColor(th), func() { a.newTab(KSandbox, "", "", true) }},
	}
	for _, c := range a.set.Containers {
		name := c.Name
		items = append(items, item{name, "Container: its own sign-ins", iconOf(c), tone(th, c.Color), func() { a.newTab(KContainer, name, "", true) }})
	}
	x := r.X + 10
	for i, it := range items {
		w := g.Measure(it.label, ui.FBodyBold) + 48
		b := ui.Rect{X: x, Y: r.Y + 8, W: w, H: r.H - 16}
		if b.R() > r.R()-150 {
			break
		}
		if u.Hover(b) {
			ui.FillRound(g, b, b.H/2, it.col.Alpha(0.14))
		}
		ui.FillRound(g, ui.Rect{X: b.X + 6, Y: b.CY() - 13, W: 26, H: 26}, 13, it.col)
		ui.DrawIcon(g, it.icon, b.X+11, b.CY()-8, 16, ui.White)
		g.Text(it.label, b.X+38, ui.Mid(g, b.Y, b.H, ui.FBodyBold), ui.FBodyBold, th.OnSurface)
		u.Tooltip(it.tip, b)
		if u.Clickable(ui.IdN("kmenu", i), b) {
			a.kindOpen = false
			it.open()
			return
		}
		x = b.R() + 4
	}
	mr := ui.Rect{X: r.R() - 146, Y: r.Y + 8, W: 100, H: r.H - 16}
	if u.Button(ID("kmanage"), mr, "Manage", ui.ButtonOpt{Icon: ui.ISettings, HasIcon: true, Tip: "Make containers and choose their icons and colors"}) {
		a.kindOpen = false
		a.openSettings("containers")
		return
	}
	if u.IconButton(ID("kclose"), ui.Rect{X: r.R() - 42, Y: r.CY() - 18, W: 36, H: 36}, ui.IClose, "Close  Esc", ui.IconOpt{}) {
		a.kindOpen = false
	}
}

// ---- the status bar, as in Vivaldi ----

func (a *App) statusBar(r ui.Rect) {
	u, g, th := &a.u, a.u.G, a.u.Th
	t := a.tab()
	live := a.livePage(t)
	cy := r.CY()
	// left: what the shield did here, and the memory the pages use
	x := r.X + 6
	if t != nil && t.URL != "" && a.shield.On {
		s := "Shield on"
		if t.Blocked > 0 {
			s = comma(t.Blocked) + " blocked"
		}
		ui.DrawIcon(g, ui.IShield, x, cy-7, 14, th.Primary)
		g.Text(s, x+20, ui.Mid(g, r.Y, r.H, ui.FSmall), ui.FSmall, th.OnSurfaceVariant)
		x += 20 + g.Measure(s, ui.FSmall) + 18
	}
	if a.memMB > 0 {
		mr := ui.Rect{X: x - 4, Y: r.Y + 2, W: g.Measure(mb(a.memMB), ui.FSmall) + 30, H: r.H - 4}
		if u.Hover(mr) {
			ui.FillRound(g, mr, mr.H/2, th.Ink.Alpha(0.06))
		}
		ui.DrawIcon(g, ui.IMemory2, x, cy-7, 14, th.OnSurfaceVariant)
		g.Text(mb(a.memMB), x+20, ui.Mid(g, r.Y, r.H, ui.FSmall), ui.FSmall, th.OnSurfaceVariant)
		u.Tooltip("Memory the pages use. Click for the memory plan.", mr)
		if u.Clickable(ID("sbmem"), mr) {
			a.openSettings("memory")
		}
	}

	// right: the page's tools, then zoom
	rx := r.R() - 4
	zw := float32(124)
	zr := ui.Rect{X: rx - zw, Y: r.Y + 2, W: zw, H: r.H - 4}
	if u.IconButton(ID("sbzin"), ui.Rect{X: zr.R() - 26, Y: zr.Y, W: 26, H: zr.H}, ui.IZoomIn, "Larger  Ctrl++", ui.IconOpt{Disabled: !live}) {
		a.zoomBy(t, 1)
	}
	if u.IconButton(ID("sbzout"), ui.Rect{X: zr.X, Y: zr.Y, W: 26, H: zr.H}, ui.IZoomOut, "Smaller  Ctrl+-", ui.IconOpt{Disabled: !live}) {
		a.zoomBy(t, -1)
	}
	mid := ui.Rect{X: zr.X + 28, Y: zr.Y, W: zr.W - 56, H: zr.H}
	if live && u.Hover(mid) {
		ui.FillRound(g, mid, mid.H/2, th.Ink.Alpha(0.06))
	}
	ui.TextCenter(g, zoomLabel(t), mid, ui.FSmallBold, th.OnSurfaceVariant)
	u.Tooltip("Back to 100%  Ctrl+0", mid)
	if live && u.Clickable(ID("sbzreset"), mid) {
		a.zoomBy(t, 0)
	}
	rx = zr.X - 6
	g.FillRect(ui.Rect{X: rx, Y: r.Y + 7, W: 1, H: r.H - 14}, th.Divider)
	rx -= 6
	tool := func(id string, ic ui.Icon, tip string, on, dis bool) bool {
		rx -= 30
		return u.IconButton(ID(id), ui.Rect{X: rx, Y: r.Y + 1, W: 28, H: r.H - 2}, ic, tip, ui.IconOpt{Toggled: on, Disabled: dis})
	}
	other, _ := a.splitWith()
	if tool("sbsplit", ui.ISplit, "Split view  Ctrl+Shift+S", other != nil, false) {
		a.toggleSplit()
	}
	if tool("sbprint", ui.IPrint, "Print, or save as PDF  Ctrl+P", false, !live) {
		a.do(actPrint)
	}
	if tool("sbfind", ui.ISearch, "Find in page  Ctrl+F", a.find.open, !live) {
		a.do(actFind)
	}
	if tool("sbhist", ui.IHistory, "History  Ctrl+H", a.panel && a.panelMode == panelHistory, false) {
		a.do(actHistory)
	}
	if tool("sbdl", ui.IDownload, "Downloads  Ctrl+Shift+D", a.panel && a.panelMode == panelDownloads, false) {
		a.do(actDownloads)
	}
	_ = x
}
