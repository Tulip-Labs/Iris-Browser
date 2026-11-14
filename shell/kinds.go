package shell

import (
	"strings"

	"litego/core"
	"litego/ui"
)

// setKind turns a new tab into another kind of tab (private, temporary,
// sandbox or a container) before anything is opened in it.
func (a *App) setKind(t *Tab, k Kind, container string) {
	if t.Kind == k && t.Container == container {
		return
	}
	if t.view != nil {
		a.unload(t)
	}
	t.Kind, t.Container = k, container
	if k == KNormal {
		a.makeSpare()
	}
	a.st.Focus = ID("ntp")
}

func sandboxColor(th *ui.Theme) ui.Color {
	if th.Dark {
		return ui.Hex("#f0a84a")
	}
	return ui.Hex("#b5650f")
}

// containerEditor draws the editor of container i (name, icon, color,
// remove) at r and returns its height.
func (a *App) containerEditor(r ui.Rect, i int) float32 {
	u, g, th := &a.u, a.u.G, a.u.Th
	c := a.set.Containers[i]
	col := tone(th, c.Color)
	x, w := r.X+14, r.W-28
	ic := float32(30)
	per := max(1, int((w+6)/(ic+6)))
	iconRows := (len(core.ContainerIcons) + per - 1) / per
	h := 12 + 46 + float32(iconRows)*(ic+6) + 6 + ic + 10 + 36 + 14
	box := ui.Rect{X: r.X, Y: r.Y, W: r.W, H: h}
	ui.Glass(g, box, 18, th, true, false)
	ey := r.Y + 12
	nr := ui.Rect{X: x, Y: ey, W: w, H: 38}
	rename := func() {
		n := strings.TrimSpace(a.contName.Text())
		if n == "" || strings.EqualFold(n, c.Name) {
			return
		}
		if _, taken := a.set.FindContainer(n); taken {
			return
		}
		for _, t := range a.tabs {
			if t.Kind == KContainer && t.Container == c.Name {
				t.Container = n
			}
		}
		a.set.Containers[i].Name = n
		a.set.Save()
	}
	u.TextField(ID("cname"), nr, a.contName, ui.FieldOpt{Placeholder: "Name", OnEnter: rename})
	if a.st.Focus != ID("cname") {
		rename()
	}
	ey += 46
	for j, name := range core.ContainerIcons {
		cr := ui.Rect{X: x + float32(j%per)*(ic+6), Y: ey + float32(j/per)*(ic+6), W: ic, H: ic}
		sel := name == c.Icon
		if sel {
			ui.FillRound(g, cr, 9, col)
		} else if u.Hover(cr) {
			ui.FillRound(g, cr, 9, th.Ink.Alpha(0.07))
		}
		icol := th.OnSurfaceVariant
		if sel {
			icol = ui.White
		}
		ui.DrawIcon(g, contIcons[name], cr.CX()-9, cr.CY()-9, 18, icol)
		if u.Clickable(ui.Id("cicon/"+name), cr) {
			a.set.Containers[i].Icon = name
			a.set.Save()
		}
	}
	ey += float32(iconRows)*(ic+6) + 6
	for j, name := range core.ContainerColors {
		cr := ui.Rect{X: x + float32(j)*(ic+6), Y: ey, W: ic, H: ic}
		cc := tone(th, name)
		ui.FillOval(g, cr.Inset(3), cc)
		if name == c.Color {
			ui.StrokeOval(g, cr.Inset(0.5), 2, cc)
		}
		u.Tooltip(strings.ToUpper(name[:1])+name[1:], cr)
		if u.Clickable(ui.Id("ccol/"+name), cr) {
			a.set.Containers[i].Color = name
			a.set.Save()
		}
	}
	ey += ic + 10
	if u.Button(ui.Id("cdone"), ui.Rect{X: x + w - 96, Y: ey, W: 96, H: 36}, "Done", ui.ButtonOpt{Primary: true}) {
		rename()
		a.editCont = -1
	}
	if u.Button(ui.Id("cdel"), ui.Rect{X: x, Y: ey, W: 130, H: 36}, "Remove", ui.ButtonOpt{Icon: ui.ITrash, HasIcon: true, Tip: "Its open tabs keep their sign-ins until they close"}) {
		a.set.Containers = append(a.set.Containers[:i], a.set.Containers[i+1:]...)
		a.set.Save()
		a.editCont = -1
	}
	return h
}
