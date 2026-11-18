package shell

import (
	"strings"

	"iris/core"
	"iris/ui"
)

var contIcons = map[string]ui.Icon{
	"briefcase": ui.IBriefcase, "person": ui.IPerson, "cart": ui.ICart, "dollar": ui.IDollar,
	"heart": ui.IHeart, "star": ui.IStar, "book": ui.IBook, "code": ui.ICode, "gamepad": ui.IGamepad,
	"home": ui.IHome, "globe": ui.IGlobe, "lab": ui.ILab,
}

var contHex = map[string]string{
	"blue": "#3b74d9", "turquoise": "#1a9e9e", "green": "#2f9e57", "yellow": "#d8a21a",
	"orange": "#e06c27", "red": "#d43c3c", "pink": "#d6458f", "purple": "#8752d1",
}

func iconOf(c core.Container) ui.Icon {
	if ic, ok := contIcons[c.Icon]; ok {
		return ic
	}
	return ui.IBriefcase
}

// tone is the color of a container, a tab kind or a label: colorless glass,
// a neutral gray that white icons read on and that reads on the backdrop
// (containers tell apart by their icon and name).
func tone(th *ui.Theme, name string) ui.Color {
	if th.Dark {
		return ui.Hex("#8e8e93")
	}
	return ui.Hex("#636366")
}

func (a *App) container(name string) core.Container {
	c, _ := a.set.FindContainer(name)
	return c
}

// contStyle is a container's icon and its themed color.
func (a *App) contStyle(name string) (ui.Icon, ui.Color) {
	c := a.container(name)
	return iconOf(c), tone(a.u.Th, c.Color)
}

// kindIcon is the icon of a tab's kind (normal tabs use home).
func (a *App) kindIcon(t *Tab) (ui.Icon, ui.Color) {
	th := a.u.Th
	switch t.Kind {
	case KPrivate:
		return ui.IPrivate, privateColor(th)
	case KTemp:
		return ui.IHourglass, tone(th, "")
	case KContainer:
		return a.contStyle(t.Container)
	case KSandbox:
		return ui.IShield, sandboxColor(th)
	}
	return ui.IHome, th.Primary
}

func privateColor(th *ui.Theme) ui.Color { return tone(th, "") }

// badge draws an icon on a filled circle (for a tab's kind).
func badge(g ui.Gfx, r ui.Rect, ic ui.Icon, bg, ring ui.Color) {
	ui.FillOval(g, r.Inset(-1.2), ring)
	ui.FillOval(g, r, bg)
	s := r.W * 0.68
	ui.DrawIcon(g, ic, r.CX()-s/2, r.CY()-s/2, s, ui.White)
}

func (a *App) addContainer(name string) bool {
	name = strings.TrimSpace(name)
	if name == "" {
		return false
	}
	if _, ok := a.set.FindContainer(name); ok {
		return false
	}
	n := len(a.set.Containers)
	a.set.Containers = append(a.set.Containers, core.Container{Name: name,
		Icon: core.ContainerIcons[(n+2)%len(core.ContainerIcons)], Color: core.ContainerColors[(n*3+1)%len(core.ContainerColors)]})
	a.set.Save()
	return true
}
