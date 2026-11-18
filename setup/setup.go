// Package setup is Iris's installer: its screens (drawn with the shared
// interface) and the per-user install, update and removal.
package setup

import (
	"bytes"
	"compress/gzip"
	"embed"
	"io"
	"math"
	"strings"
	"sync"

	"iris/ui"
)

// Version is the Iris version this setup installs.
const Version = "1.0.0"

//go:embed payload
var payload embed.FS

// appBytes is the embedded Iris app (nil when the setup was built without it).
func appBytes() []byte {
	b, err := payload.ReadFile("payload/Iris.exe.gz")
	if err != nil {
		return nil
	}
	zr, err := gzip.NewReader(bytes.NewReader(b))
	if err != nil {
		return nil
	}
	out, err := io.ReadAll(zr)
	if err != nil {
		return nil
	}
	return out
}

type stage uint8

const (
	stWelcome stage = iota
	stWorking
	stDone
	stError
	stUninstall
	stUninstalling
	stRemoved
)

// Host is the setup window.
type Host interface {
	Invalidate()
	Minimize()
	Close()
}

type step struct {
	label string
	state uint8 // 0 waiting, 1 running, 2 done, 3 skipped
}

// Setup is the installer's interface and its work.
type Setup struct {
	h  Host
	In *ui.Input
	st ui.State
	u  ui.Ui
	th *ui.Theme

	MoveAreas []ui.Rect

	mu        sync.Mutex
	stage     stage
	steps     []step
	progress  float32
	err       string
	desktop   bool
	openAfter bool
	wipe      bool
	existing  string

	// work hooks (replaced in tests)
	work func(s *Setup)
}

// New makes the setup screens; uninstallMode starts on the removal page.
func New(h Host, uninstallMode bool) *Setup {
	s := &Setup{h: h, In: ui.NewInput(), th: ui.ThemeByID("crocus"), desktop: true, openAfter: true, existing: installedVersion()}
	if uninstallMode {
		s.stage = stUninstall
	}
	s.work = runInstall
	return s
}

func (s *Setup) set(f func()) {
	s.mu.Lock()
	f()
	s.mu.Unlock()
	s.h.Invalidate()
}

func (s *Setup) fail(err error) {
	s.set(func() { s.stage, s.err = stError, sentence(err.Error()) })
}

func sentence(s string) string {
	if s == "" {
		return s
	}
	s = strings.ToUpper(s[:1]) + s[1:]
	if !strings.HasSuffix(s, ".") {
		s += "."
	}
	return s
}

// runInstall does the install, reporting each step.
func runInstall(s *Setup) {
	s.set(func() {
		s.steps = []step{{"Checking the web engine", 0}, {"Copying Iris", 0}, {"Adding shortcuts", 0}, {"Registering Iris as a browser", 0}}
		s.progress = 0
	})
	mark := func(i int, st uint8, p float32) { s.set(func() { s.steps[i].state, s.progress = st, p }) }
	app := appBytes()
	if app == nil {
		s.fail(errString("this setup was built without the app inside; build it with build-iris"))
		return
	}
	dir := installDir()
	mark(0, 1, 0.05)
	if !engineInstalled() {
		s.set(func() { s.steps[0].label = "Installing Microsoft Edge WebView2" })
		if err := installEngine(func(p float32) { s.set(func() { s.progress = 0.05 + p*0.4 }) }); err != nil {
			s.fail(err)
			return
		}
	}
	mark(0, 2, 0.45)
	mark(1, 1, 0.5)
	if err := copyApp(dir, app); err != nil {
		s.fail(err)
		return
	}
	mark(1, 2, 0.75)
	mark(2, 1, 0.8)
	if err := makeShortcuts(dir, s.desktop); err != nil {
		s.fail(err)
		return
	}
	mark(2, 2, 0.88)
	mark(3, 1, 0.9)
	if err := register(dir, len(app)); err != nil {
		s.fail(err)
		return
	}
	mark(3, 2, 1)
	s.set(func() { s.stage = stDone })
	if s.openAfter {
		launch(dir)
	}
}

type errString string

func (e errString) Error() string { return string(e) }

// Frame draws the setup window.
func (s *Setup) Frame(g ui.Gfx, w, h float32) {
	s.mu.Lock()
	defer s.mu.Unlock()
	th := s.th
	u := &s.u
	u.G, u.In, u.Th, u.St = g, s.In, th, &s.st
	u.W, u.H, u.Layer, u.InputLayer, u.Redraw = w, h, 0, 0, false
	s.MoveAreas = s.MoveAreas[:0]

	g.FillRect(ui.Rect{W: w, H: h}, th.Surface)
	// title bar: drag anywhere, minimize and close at the right
	s.MoveAreas = append(s.MoveAreas, ui.Rect{W: w - 92, H: 40})
	for i, ic := range []ui.Icon{ui.IMinimize, ui.IClose} {
		br := ui.Rect{X: w - 92 + float32(i)*46, W: 46, H: 36}
		hot := u.Hover(br)
		col := th.OnSurfaceVariant
		if hot && i == 1 {
			g.FillRect(br, ui.Hex("#c42b1c"))
			col = ui.White
		} else if hot {
			g.FillRect(br, th.Ink.Alpha(0.07))
		}
		ui.DrawIcon(g, ic, br.CX()-8, br.CY()-8, 16, col)
		if u.Clickable(ui.IdN("win", i), br) {
			if i == 0 {
				s.h.Minimize()
			} else if s.stage != stWorking && s.stage != stUninstalling {
				s.h.Close()
			}
		}
	}
	cx := w / 2
	switch s.stage {
	case stWelcome:
		s.welcome(cx, w, h)
	case stWorking, stUninstalling:
		s.working(cx, w, h)
	case stDone:
		s.result(cx, w, h, ui.ICheck, "Iris is ready", "Find it in the Start menu. To make it your default browser, choose Iris in Windows Settings > Apps > Default apps.", "Open Iris", true)
	case stError:
		s.result(cx, w, h, ui.IWarning, "Setup could not finish", s.err, "Try again", false)
	case stUninstall:
		s.uninstallPage(cx, w, h)
	case stRemoved:
		s.result(cx, w, h, ui.ICheck, "Iris was removed", "Thanks for trying it.", "", false)
	}
	u.DrawTooltip()
	s.In.EndFrame()
	if u.Redraw {
		s.h.Invalidate()
	}
}

func (s *Setup) header(cx, y float32, title, sub string, w float32) float32 {
	g, th := s.u.G, s.th
	logo(g, ui.RectAround(cx, y+34, 68, 68), th)
	y += 92
	ui.TextCenter(g, title, ui.Rect{X: 0, Y: y, W: w, H: 34}, ui.FBig, th.OnSurface)
	y += 36
	if sub != "" {
		ui.TextCenter(g, sub, ui.Rect{X: 0, Y: y, W: w, H: 22}, ui.FBody, th.OnSurfaceVariant)
		y += 24
	}
	return y
}

func (s *Setup) welcome(cx, w, h float32) {
	u, g, th := &s.u, s.u.G, s.th
	y := s.header(cx, 36, "Iris", "A light, fast browser for Google and YouTube.", w)
	card := ui.Rect{X: 40, Y: y + 16, W: w - 80, H: 160}
	ui.Glass(g, card, 20, th, true, true)
	feats := []struct {
		ic   ui.Icon
		text string
	}{
		{ui.IMemory2, "Opens instantly; background tabs sleep, so memory stays low"},
		{ui.ISparkle, "Google results and AI answers in its own look, and Ask AI on any page"},
		{ui.IShield, "A built-in shield against ads and trackers"},
		{ui.IPrivate, "Private, temporary and container tabs"},
	}
	for i, f := range feats {
		ry := card.Y + 14 + float32(i)*34
		ib := ui.Rect{X: card.X + 18, Y: ry, W: 28, H: 28}
		ui.FillRound(g, ib, 9, th.SecondaryContainer)
		ui.DrawIcon(g, f.ic, ib.X+5, ib.Y+5, 18, th.OnSecondaryContainer)
		ui.TextFit(g, f.text, ib.R()+12, ui.Mid(g, ry, 28, ui.FBody), ui.FBody, th.OnSurface, card.R()-ib.R()-28)
	}
	y = card.B() + 10
	s.desktop = u.Checkbox(ui.Id("desk"), ui.Rect{X: 44, Y: y, W: 200, H: 34}, "Desktop shortcut", s.desktop)
	s.openAfter = u.Checkbox(ui.Id("open"), ui.Rect{X: 250, Y: y, W: 220, H: 34}, "Open Iris when done", s.openAfter)
	// footer
	fy := h - 64
	g.FillRect(ui.Rect{X: 0, Y: fy - 1, W: w, H: 1}, th.Divider)
	note := "Installs for you only, no administrator rights."
	if s.existing != "" {
		note = "Iris " + s.existing + " is installed. Your tabs and settings are kept."
	}
	ui.TextFit(g, note, 24, ui.Mid(g, fy, 64, ui.FSmall), ui.FSmall, th.OnSurfaceVariant, w-220)
	label := "Install"
	if s.existing != "" {
		label = "Update"
	}
	if u.Button(ui.Id("install"), ui.Rect{X: w - 24 - 150, Y: fy + 12, W: 150, H: 40}, label, ui.ButtonOpt{Primary: true, Icon: ui.IExport, HasIcon: true}) {
		s.stage = stWorking
		go s.work(s)
	}
}

func (s *Setup) working(cx, w, h float32) {
	u, g, th := &s.u, s.u.G, s.th
	title := "Installing Iris"
	if s.stage == stUninstalling {
		title = "Removing Iris"
	}
	y := s.header(cx, 36, title, "", w)
	y += 10
	u.Redraw = true
	now := u.In.Now
	for _, st := range s.steps {
		r := ui.Rect{X: 96, Y: y, W: w - 192, H: 36}
		ic := ui.RectAround(r.X+12, r.CY(), 22, 22)
		col := th.OnSurfaceVariant
		switch st.state {
		case 2:
			ui.FillOval(g, ic, th.Primary)
			ui.DrawIcon(g, ui.ICheck, ic.X+3, ic.Y+3, 16, th.OnPrimary)
			col = th.OnSurface
		case 1:
			ph := float32(math.Mod(now*360, 360))
			ui.StrokeOval(g, ic.Inset(2), 2.2, th.Primary.Alpha(0.2))
			ui.Pen(g, ui.NewPath().Arc(ic.CX(), ic.CY(), 9, ph, ph+110, true), 2.2, th.Primary)
			col = th.OnSurface
		default:
			ui.StrokeOval(g, ic.Inset(2), 1.5, th.Outline)
		}
		f := ui.FBody
		if st.state == 1 {
			f = ui.FBodyBold
		}
		g.Text(st.label, r.X+36, ui.Mid(g, r.Y, r.H, f), f, col)
		y += 38
	}
	// progress: an M3 linear indicator with the accent
	pr := ui.Rect{X: 96, Y: h - 70, W: w - 192, H: 6}
	ui.FillRound(g, pr, 3, th.SecondaryContainer)
	if s.progress > 0 {
		ui.FillRoundAccent(g, ui.Rect{X: pr.X, Y: pr.Y, W: max(6, pr.W*s.progress), H: pr.H}, 3, th.Primary)
	}
}

func (s *Setup) result(cx, w, h float32, ic ui.Icon, title, text, action string, primaryOpens bool) {
	u, g, th := &s.u, s.u.G, s.th
	y := float32(84)
	badge := ui.RectAround(cx, y+30, 72, 72)
	base := th.Primary
	if ic == ui.IWarning {
		base = th.Danger
	}
	ui.Shadow(g, badge, 36, th.Shadow, 0.8, 3)
	ui.FillOval(g, badge, base)
	g.FillPathGradient(ui.NewPath().Ellipse(badge), ui.White.Alpha(0.22), ui.White.Alpha(0), badge.Y, badge.B())
	ui.DrawIcon(g, ic, badge.CX()-18, badge.CY()-18, 36, ui.White)
	y = badge.B() + 26
	ui.TextCenter(g, title, ui.Rect{W: w, Y: y, H: 34}, ui.FBig, th.OnSurface)
	y += 44
	tw := w - 120
	for _, ln := range wrap(g, text, ui.FBody, tw) {
		ui.TextCenter(g, ln, ui.Rect{X: 60, Y: y, W: tw, H: 22}, ui.FBody, th.OnSurfaceVariant)
		y += 22
	}
	by := h - 76
	if action != "" {
		bw := g.Measure(action, ui.FBodyBold) + 56
		if u.Button(ui.Id("act"), ui.Rect{X: cx - bw - 6, Y: by, W: bw, H: 42}, action, ui.ButtonOpt{Primary: true}) {
			if primaryOpens {
				launch(installDir())
				s.h.Close()
			} else {
				s.stage = stWorking
				go s.work(s)
			}
		}
		if u.Button(ui.Id("close"), ui.Rect{X: cx + 6, Y: by, W: 120, H: 42}, "Close", ui.ButtonOpt{}) {
			s.h.Close()
		}
	} else if u.Button(ui.Id("close"), ui.Rect{X: cx - 60, Y: by, W: 120, H: 42}, "Close", ui.ButtonOpt{Primary: true}) {
		s.h.Close()
	}
}

func (s *Setup) uninstallPage(cx, w, h float32) {
	u, g, th := &s.u, s.u.G, s.th
	y := s.header(cx, 48, "Remove Iris?", "The app, its shortcuts and its browser registration are removed.", w)
	y += 24
	s.wipe = u.Checkbox(ui.Id("wipe"), ui.Rect{X: cx - 190, Y: y, W: 380, H: 36}, "Also delete history, settings and site data", s.wipe)
	_ = th
	by := h - 76
	if u.Button(ui.Id("remove"), ui.Rect{X: cx - 136, Y: by, W: 130, H: 42}, "Remove", ui.ButtonOpt{Danger: true}) {
		s.stage = stUninstalling
		s.steps = []step{{"Removing shortcuts and registration", 1}, {"Removing the app", 0}}
		wipe := s.wipe
		go func() {
			err := uninstall(wipe)
			if err != nil {
				s.fail(err)
				return
			}
			s.set(func() { s.steps[0].state, s.steps[1].state, s.progress, s.stage = 2, 2, 1, stRemoved })
		}()
	}
	if u.Button(ui.Id("cancel"), ui.Rect{X: cx + 6, Y: by, W: 130, H: 42}, "Keep it", ui.ButtonOpt{}) {
		s.h.Close()
	}
	_ = g
}

func logo(g ui.Gfx, r ui.Rect, th *ui.Theme) {
	ui.Shadow(g, r, r.W*0.3, th.Shadow, 0.9, 3)
	ui.FillRoundAccent(g, r, r.W*0.3, th.Primary)
	s := r.W / 24
	ui.Pen(g, ui.NewPath().Arc(r.CX(), r.CY(), 6.6*s, 140, 470, true), 2.1*s, ui.White)
	ui.FillOval(g, ui.RectAround(r.X+17.2*s, r.Y+7.4*s, 4.6*s, 4.6*s), th.Hl)
	ui.FillOval(g, ui.RectAround(r.CX(), r.CY(), 3.2*s, 3.2*s), ui.White)
}

func wrap(g ui.Gfx, text string, f ui.Font, w float32) []string {
	var out []string
	line := ""
	for _, word := range strings.Fields(text) {
		try := word
		if line != "" {
			try = line + " " + word
		}
		if g.Measure(try, f) > w && line != "" {
			out = append(out, line)
			line = word
		} else {
			line = try
		}
	}
	if line != "" {
		out = append(out, line)
	}
	return out
}
