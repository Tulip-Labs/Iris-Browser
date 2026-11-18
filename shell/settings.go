package shell

import (
	"strconv"
	"strings"

	"litego/core"
	"litego/ui"
)

// Settings live in the menu (the ⋮ button), in sections that open in place.

type settingsSection struct {
	id, label, tip string
	icon           ui.Icon
}

var settingsSections = []settingsSection{
	{"look", "Appearance", "Palettes", ui.IPalette},
	{"containers", "Containers", "Separate sign-ins: their names, icons and colors", ui.IContainer},
	{"memory", "Memory", "How soon tabs rest, and freeing memory now", ui.IMemory2},
	{"data", "History and data", "Reopening tabs and clearing history", ui.IHistory},
	{"about", "About and updates", "Version, integrity, updates and license", ui.IInfo},
}

// openSettings opens the menu at section sec.
func (a *App) openSettings(sec string) {
	a.panel, a.panelMode = true, panelSettings
	a.ai.open = false
	if sec != "" {
		a.setSec = sec
	}
}

// containerSettings lists the containers with their editor, and adds new ones.
func (a *App) containerSettings(x, y, w float32) float32 {
	u, g, th := &a.u, a.u.G, a.u.Th
	y += 10
	g.Text("Containers", x, y+16, ui.FTitle, th.OnSurface)
	y += 34
	for _, ln := range wrap(g, "Each container keeps its own sign-ins, cookies and site data, apart from your other tabs: a work account and a personal one side by side. Open a tab in one from the arrow beside + in the tab strip.", ui.FSmall, w) {
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
		ui.Liquid(g, ui.Rect{X: row.X + 12, Y: row.CY() - 15, W: 30, H: 30}, 10, th.Ink)
		ui.DrawIcon(g, iconOf(c), row.X+18, row.CY()-9, 18, th.Ink)
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
