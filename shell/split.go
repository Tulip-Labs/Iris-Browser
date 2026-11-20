package shell

import (
	"encoding/json"
	"math"
	"strconv"

	"iris/ui"
)

// splitView is two tabs side by side: a on the left, b on the right. The pair
// shows whenever one of the two is the current tab; picking any other tab
// shows that tab alone, and coming back to one of the pair brings both back.
type splitView struct {
	a, b  *Tab
	ratio float32 // the left pane's share of the width
	drag  bool
}

const splitGap = 10

// splitWith returns the tab shown beside the current one, and whether the
// current one is on the left; nil when the split is not showing.
func (a *App) splitWith() (*Tab, bool) {
	s := &a.split
	if s.a == nil || s.b == nil || a.Fullscreen() {
		return nil, false
	}
	switch a.tab() {
	case s.a:
		return s.b, true
	case s.b:
		return s.a, false
	}
	return nil, false
}

// toggleSplit opens a second pane beside the current tab (a new tab, ready
// for an address), or goes back to one pane; both tabs stay open.
func (a *App) toggleSplit() {
	if a.split.a != nil && a.split.b != nil {
		if other, _ := a.splitWith(); other != nil || a.tab() == nil {
			a.split.a, a.split.b = nil, nil
			a.prioritize()
			return
		}
	}
	cur := a.tab()
	if cur == nil {
		return
	}
	if a.u.W > 0 && a.u.W < 640 {
		a.notify("The window is too narrow for two pages side by side.")
		return
	}
	a.winFull = a.winFull && !a.full
	n := a.newTab(KNormal, "", "", true)
	a.split.a, a.split.b = cur, n
	if a.split.ratio < 0.25 || a.split.ratio > 0.75 {
		a.split.ratio = 0.5
	}
	a.prioritize()
}

// panes splits the page area in two when the split shows: the current tab's
// part, the other tab's part, and that tab. It also draws the divider (drag
// it to resize) and keeps the other tab's page loaded and awake.
func (a *App) panes(page ui.Rect) (ui.Rect, ui.Rect, *Tab) {
	other, left := a.splitWith()
	if other == nil || page.W < 620 || page.H < 80 {
		a.split.drag = false
		return page, ui.Rect{}, nil
	}
	u, g, th := &a.u, a.u.G, a.u.Th
	s := &a.split
	in := a.In
	span := page.W - splitGap
	bar := ui.Rect{X: page.X + span*s.ratio, Y: page.Y, W: splitGap, H: page.H}
	if in.Pressed && u.Live() && bar.Inset(-3).Contains(in.MX, in.MY) {
		s.drag = true
	}
	if s.drag {
		if in.Down {
			s.ratio = min(0.75, max(0.25, (in.MX-page.X-splitGap/2)/span))
			u.Redraw = true
		} else {
			s.drag = false
		}
		bar.X = page.X + span*s.ratio
	}
	if s.drag || u.Hover(bar) {
		ui.FillRound(g, ui.RectAround(bar.CX(), bar.CY(), 4, 44), 2, th.Primary)
	} else {
		ui.FillRound(g, ui.RectAround(bar.CX(), bar.CY(), 4, 28), 2, th.Outline.Alpha(0.5))
	}
	u.Tooltip("Drag to resize", bar)
	l := ui.Rect{X: page.X, Y: page.Y, W: bar.X - page.X, H: page.H}
	r := ui.Rect{X: bar.R(), Y: page.Y, W: page.R() - bar.R(), H: page.H}
	mine, beside := l, r
	if !left {
		mine, beside = r, l
	}
	// a line under the pane that has the keyboard
	ui.FillRound(g, ui.Rect{X: mine.X + 12, Y: mine.B() + 2.5, W: mine.W - 24, H: 3}, 1.5, th.Primary)
	// the other page stays loaded and awake while it shows
	if other.view == nil && other.URL != "" && !other.making && !other.Crashed {
		other.pending = other.URL
		a.ensureView(other)
	}
	if other.asleep && other.view != nil {
		v := other.view
		a.web(v.Wake)
		other.asleep = false
	}
	return mine, beside, other
}

// otherPane draws the pane of the tab beside the current one. Its page, when
// it has one, is a live view placed there by sync; anything else (a new tab,
// a stopped page) shows as a card that takes the keyboard when
// clicked, and then draws in full as the current tab.
func (a *App) otherPane(r ui.Rect, t *Tab) {
	u, g, th := &a.u, a.u.G, a.u.Th
	fillPage(g, r, 14, th)
	if t.URL != "" && !t.Crashed {
		if t.view == nil || !t.shown {
			spinner(u, r.CX(), r.CY(), 13)
		}
		return
	}
	hot := u.Hover(r)
	if hot {
		ui.FillRound(g, r, 14, th.Ink.Alpha(0.04))
	}
	ic, col := a.kindIcon(t)
	title, sub := "New tab", "Click here to use this side"
	switch {
	case t.Crashed:
		ic, title = ui.IWarning, "This page stopped"
	case t.Kind == KNormal:
		ic = ui.IPlus
	}
	tile := ui.RectAround(r.CX(), r.CY()-34, 56, 56)
	ui.FillRound(g, tile, 18, col.Alpha(0.14))
	ui.DrawIcon(g, ic, tile.CX()-13, tile.CY()-13, 26, col)
	ui.TextCenter(g, ui.Fit(g, title, ui.FTitle, r.W-40), ui.Rect{X: r.X, Y: r.CY() + 6, W: r.W, H: 26}, ui.FTitle, th.OnSurface)
	ui.TextCenter(g, sub, ui.Rect{X: r.X, Y: r.CY() + 34, W: r.W, H: 20}, ui.FBody, th.OnSurfaceVariant)
	if u.Clickable(ID("otherpane"), r) {
		a.selectTab(a.indexOf(t))
	}
}

func (a *App) indexOf(t *Tab) int {
	for i, x := range a.tabs {
		if x == t {
			return i
		}
	}
	return -1
}

// pageFocused runs when a page takes the keyboard (a click inside it): in
// split view that pane becomes the current tab, and the address bar lets go.
func (a *App) pageFocused(t *Tab) {
	if other, _ := a.splitWith(); other == t {
		a.selectTab(a.indexOf(t))
		return
	}
	if t == a.tab() && (a.st.Focus == ID("addr") || a.st.Focus == ID("find")) {
		a.st.Focus = ui.ID{}
		a.sugg = nil
	}
}

// ---- find in page, zoom ----

type findBar struct {
	open  bool
	q     *ui.TextEdit
	last  string
	count int // matches on the page (-1 = not counted yet)
}

func (a *App) livePage(t *Tab) bool {
	return t != nil && t.view != nil && t.URL != "" && !t.Crashed
}

func (a *App) openFind() {
	if !a.livePage(a.tab()) {
		a.notify("Find works on web pages.")
		return
	}
	a.find.open, a.find.last, a.find.count = true, "", -1
	a.st.Focus = ID("find")
	a.find.q.SelectAll()
	a.web(a.h.FocusWindow)
}

func (a *App) closeFind() {
	if !a.find.open {
		return
	}
	a.find.open = false
	if a.st.Focus == ID("find") {
		a.st.Focus = ui.ID{}
	}
	if t := a.tab(); a.livePage(t) {
		v := t.view
		a.web(func() { v.Eval("try{getSelection().removeAllRanges()}catch(e){}") })
	}
}

// findNext selects the next (or previous) match in the page. A changed text
// starts again from the top and counts the matches.
func (a *App) findNext(back bool) {
	t := a.tab()
	q := a.find.q.Text()
	if !a.livePage(t) || q == "" {
		a.find.count, a.find.last = -1, ""
		return
	}
	v := t.view
	lit := jsStr(q)
	fresh := q != a.find.last
	a.find.last = q
	js := "window.find(" + lit + ",false," + boolJS(back) + ",true)"
	if fresh {
		js = "try{getSelection().removeAllRanges()}catch(e){};" + js
		a.find.count = -1
		count := "(()=>{const t=(document.body?document.body.innerText:'').toLowerCase(),q=" + lit + ".toLowerCase();let n=0,i=0;while((i=t.indexOf(q,i))>=0){n++;i+=q.length;if(n>9999)break}return n})()"
		a.web(func() {
			v.Run(count, func(res string) {
				a.post(func() {
					if a.find.last == q {
						a.find.count = atoi(res)
					}
				})
			})
		})
	}
	a.web(func() { v.Eval(js) })
}

// jsStr writes s as a JavaScript string.
func jsStr(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}

// spinner draws a turning arc: something is on its way.
func spinner(u *ui.Ui, cx, cy, r float32) {
	a0 := float32(math.Mod(u.In.Now*300, 360))
	ui.Pen(u.G, ui.NewPath().Arc(cx, cy, r, a0, a0+250, true), 2.6, u.Th.Primary)
	u.Redraw = true
}

func boolJS(b bool) string {
	if b {
		return "true"
	}
	return "false"
}

func atoi(s string) int {
	n := 0
	for _, c := range s {
		if c < '0' || c > '9' {
			break
		}
		n = n*10 + int(c-'0')
	}
	return n
}

func (a *App) findBar(r ui.Rect) {
	u, g, th := &a.u, a.u.G, a.u.Th
	ui.FillRound(g, r, 14, th.SurfaceHigh)
	if u.IconButton(ID("findx"), ui.Rect{X: r.R() - 38, Y: r.CY() - 16, W: 32, H: 32}, ui.IClose, "Close  Esc", ui.IconOpt{}) {
		a.closeFind()
		return
	}
	next := u.IconButton(ID("findn"), ui.Rect{X: r.R() - 74, Y: r.CY() - 16, W: 32, H: 32}, ui.IChevronDown, "Next  Enter", ui.IconOpt{})
	if u.IconButton(ID("findp"), ui.Rect{X: r.R() - 110, Y: r.CY() - 16, W: 32, H: 32}, ui.IChevronLeft, "Previous  Shift+Enter", ui.IconOpt{}) {
		a.findNext(true)
	}
	if next {
		a.findNext(false)
	}
	label := ""
	switch {
	case a.find.q.Text() == "" || a.find.last == "":
	case a.find.count == 0:
		label = "No matches"
	case a.find.count == 1:
		label = "1 match"
	case a.find.count > 1:
		label = comma(a.find.count) + " matches"
	}
	lw := g.Measure(label, ui.FSmall)
	g.Text(label, r.R()-122-lw, ui.Mid(g, r.Y, r.H, ui.FSmall), ui.FSmall, th.OnSurfaceVariant)
	fr := ui.Rect{X: r.X + 6, Y: r.Y + 3, W: min(420, r.W-150-lw), H: r.H - 6}
	if a.st.Focus == ID("find") && a.In.Has(ui.KEscape, false) {
		a.closeFind()
		return
	}
	shift := a.In.Shift
	u.TextField(ID("find"), fr, a.find.q, ui.FieldOpt{Placeholder: "Find in this page",
		OnEnter: func() { a.findNext(shift) }})
	if q := a.find.q.Text(); q != a.find.last && a.st.Focus == ID("find") {
		a.findNext(false) // search as you type
	}
}

var zoomSteps = []float64{0.5, 0.67, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3}

// zoomBy makes the page larger (dir 1), smaller (-1) or its normal size (0).
func (a *App) zoomBy(t *Tab, dir int) {
	if !a.livePage(t) {
		return
	}
	z := t.zoom
	if z == 0 {
		z = 1
	}
	i := 0
	for j, s := range zoomSteps {
		if s <= z+0.001 {
			i = j
		}
	}
	switch {
	case dir == 0:
		z = 1
	case dir > 0 && i+1 < len(zoomSteps):
		z = zoomSteps[i+1]
	case dir < 0 && i > 0:
		z = zoomSteps[i-1]
	}
	t.zoom = z
	v := t.view
	a.web(func() { v.SetZoom(z) })
}

func zoomLabel(t *Tab) string {
	if t == nil || t.zoom == 0 || t.zoom == 1 {
		return "100%"
	}
	return strconv.Itoa(int(t.zoom*100+0.5)) + "%"
}
