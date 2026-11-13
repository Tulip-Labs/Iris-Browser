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

// kindPicker is the row of cards on the new tab page that says what kind of
// tab this is: a normal one, private, temporary, a sandbox, or one of the
// containers (made and edited right here). It returns the height it used.
func (a *App) kindPicker(cx, top, maxW float32, t *Tab) float32 {
	u, g, th := &a.u, a.u.G, a.u.Th
	type card struct {
		kind  Kind
		cont  int // index of the container, -1 for none
		label string
		tip   string
		icon  ui.Icon
		col   ui.Color
	}
	cards := []card{
		{KNormal, -1, "Normal", "Your everyday tab: keeps history and sign-ins", ui.IHome, th.Primary},
		{KPrivate, -1, "Private", "Nothing is kept after the last private tab closes  Ctrl+Shift+N", ui.IPrivate, privateColor(th)},
		{KTemp, -1, "Temporary", "A fresh session for this tab alone, wiped when it closes", ui.IHourglass, ui.Mix(th.Hl, th.Ink, 0.25)},
		{KSandbox, -1, "Sandbox", "For a site you do not trust: no downloads, no camera, microphone or location, nothing kept", ui.IShield, sandboxColor(th)},
	}
	for i, c := range a.set.Containers {
		cards = append(cards, card{KContainer, i, c.Name, c.Name + ": its own sign-ins and cookies, kept apart", iconOf(c), tone(th, c.Color)})
	}
	const cw, ch, gap = 104, 78, 8
	n := len(cards) + 1 // and the card that adds a container
	per := max(1, min(n, int((maxW+gap)/(cw+gap))))
	rows := (n + per - 1) / per
	y := top
	ui.TextCenter(g, "Open this tab as", ui.Rect{X: cx - maxW/2, Y: y, W: maxW, H: 18}, ui.FSmallBold, th.OnSurfaceVariant)
	y += 26
	at := func(i int) ui.Rect {
		row := i / per
		in := per
		if row == rows-1 {
			in = n - row*per
		}
		rowW := float32(in)*(cw+gap) - gap
		return ui.Rect{X: cx - rowW/2 + float32(i%per)*(cw+gap), Y: y + float32(row)*(ch+gap), W: cw, H: ch}
	}
	for i, c := range cards {
		r := at(i)
		sel := t.Kind == c.kind && (c.kind != KContainer || t.Container == a.set.Containers[c.cont].Name)
		hot := u.Hover(r)
		switch {
		case sel:
			ui.FillRound(g, r, 18, c.col.Alpha(0.16))
			ui.StrokeRound(g, r.Inset(1), 17, 2, c.col)
		case hot:
			ui.FillRound(g, r, 18, th.Ink.Alpha(0.07))
		default:
			ui.FillRound(g, r, 18, th.Ink.Alpha(0.035))
		}
		tile := ui.RectAround(r.CX(), r.Y+28, 34, 34)
		ui.FillRoundAccent(g, tile, 11, c.col)
		ui.DrawIcon(g, c.icon, tile.CX()-9, tile.CY()-9, 18, ui.White)
		ui.TextCenter(g, ui.Fit(g, c.label, ui.FSmallBold, cw-12), ui.Rect{X: r.X, Y: r.Y + 50, W: r.W, H: 20}, ui.FSmallBold, th.OnSurface)
		edited := false
		if c.cont >= 0 && (hot || a.editCont == c.cont) {
			eb := ui.Rect{X: r.R() - 30, Y: r.Y + 4, W: 26, H: 26}
			if u.IconButton(ui.IdN("kedit", c.cont), eb, ui.IEdit, "Edit "+c.label, ui.IconOpt{Toggled: a.editCont == c.cont}) {
				edited = true
				if a.editCont == c.cont {
					a.editCont = -1
				} else {
					a.editCont = c.cont
					a.contName.Set(c.label)
				}
			}
		}
		u.Tooltip(c.tip, r)
		if u.Clickable(ui.IdN("kind", i), r) && !edited {
			name := ""
			if c.cont >= 0 {
				name = a.set.Containers[c.cont].Name
			}
			a.setKind(t, c.kind, name)
		}
	}
	// the card that adds a container
	ar := at(n - 1)
	adding := a.editCont == -2
	if adding {
		ui.FillRound(g, ar, 18, th.Primary.Alpha(0.14))
	} else if u.Hover(ar) {
		ui.FillRound(g, ar, 18, th.Ink.Alpha(0.07))
	}
	ui.StrokeRound(g, ar.Inset(0.5), 18, 1, th.Outline.Alpha(0.6))
	ui.DrawIcon(g, ui.IPlus, ar.CX()-11, ar.Y+17, 22, th.Primary)
	ui.TextCenter(g, "Container", ui.Rect{X: ar.X, Y: ar.Y + 50, W: ar.W, H: 20}, ui.FSmallBold, th.OnSurfaceVariant)
	u.Tooltip("A container keeps its own sign-ins: work, a second account, shopping", ar)
	if u.Clickable(ID("kadd"), ar) {
		if adding {
			a.editCont = -1
		} else {
			a.editCont = -2
			a.newCont.Set("")
			a.st.Focus = ID("contname")
		}
	}
	y += float32(rows)*(ch+gap) + 4

	ew := min(maxW, 440)
	ex := cx - ew/2
	switch {
	case a.editCont == -2:
		// a name is all a new container needs
		box := ui.Rect{X: ex, Y: y, W: ew, H: 62}
		ui.Glass(g, box, 18, th, true, false)
		fr := ui.Rect{X: box.X + 12, Y: box.Y + 12, W: box.W - 24 - 96, H: 38}
		add := func() {
			if a.addContainer(a.newCont.Text()) {
				c := a.set.Containers[len(a.set.Containers)-1]
				a.newCont.Set("")
				a.editCont = -1
				a.setKind(t, KContainer, c.Name)
			}
		}
		u.TextField(ID("contname"), fr, a.newCont, ui.FieldOpt{Placeholder: "Name: Work, Shopping…", OnEnter: add})
		if u.Button(ID("contadd"), ui.Rect{X: fr.R() + 8, Y: fr.Y + 1, W: 88, H: 36}, "Add", ui.ButtonOpt{Primary: true}) {
			add()
		}
		y += box.H + 8
	case a.editCont >= 0 && a.editCont < len(a.set.Containers):
		y += a.containerEditor(ui.Rect{X: ex, Y: y, W: ew}, a.editCont) + 8
	case a.editCont >= len(a.set.Containers):
		a.editCont = -1
	}
	return y - top
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
