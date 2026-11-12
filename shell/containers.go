package shell

import (
	"strings"

	"litego/core"
	"litego/ui"
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

// tone fits a container color to the palette: a touch of the theme's primary in
// light themes, lifted for dark ones, so every container sits well in every theme.
func tone(th *ui.Theme, name string) ui.Color {
	h, ok := contHex[name]
	if !ok {
		h = contHex["blue"]
	}
	c := ui.Hex(h)
	if th.Dark {
		return ui.Mix(c, ui.White, 0.22)
	}
	return ui.Mix(c, th.Deep, 0.12)
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
		return ui.IHourglass, ui.Mix(th.Hl, th.Ink, 0.25)
	case KContainer:
		return a.contStyle(t.Container)
	}
	return ui.IHome, th.Primary
}

func privateColor(th *ui.Theme) ui.Color {
	if th.Dark {
		return ui.Hex("#b99cff")
	}
	return ui.Hex("#5b3f8c")
}

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
