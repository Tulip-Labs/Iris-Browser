package shell

import (
	"testing"

	"litego/ui"
)

func newPhone(t *testing.T) *driver {
	d := &driver{t: t, w: 412, h: 892}
	d.eng = &fakeEngine{}
	d.a = New(&fakeHost{}, Config{TotalMB: 4096, Version: "1.0", Engine: d.eng, Mobile: true})
	d.a.set.GoogleSignIn = "later"
	d.a.Started(nil)
	d.a.In.Now = 1
	d.a.Insets = [4]float32{32, 0, 24, 0} // a status bar and a gesture bar
	return d
}

func TestPhone(t *testing.T) {
	d := newPhone(t)
	d.frames(2)
	d.shot("phone-ntp")
	in := d.a.Insets
	// nothing is drawn under the status bar except the frame color, and the
	// bottom buttons sit above the gesture bar
	if a := d.a; len(a.tabs) != 1 || a.tab().URL != "" {
		t.Fatalf("starts on one new tab page: %d tabs", len(a.tabs))
	}

	// a page fills the space between the bars
	d.a.navigate(d.a.tab(), "https://github.com/")
	d.frames(3)
	v := d.eng.views[len(d.eng.views)-1]
	if !v.visible {
		t.Fatal("the page is shown")
	}
	top, bottom := float32(v.bounds[1]), float32(v.bounds[1]+v.bounds[3])
	if top < in[0]+mBarH-1 || bottom > d.h-in[2]-mNavH+1 || v.bounds[2] != int(d.w) {
		t.Fatalf("page bounds %v: between the address row and the bottom buttons, full width", v.bounds)
	}
	d.a.tab().Title = "GitHub"
	d.a.tab().Blocked = 12
	d.frame()
	d.shot("phone-page")

	// the tabs button opens the grid; the page is hidden while it shows
	navY := d.h - in[2] - mNavH/2
	slot := d.w / 5
	d.a.newTab(KNormal, "", "https://www.youtube.com/", true)
	d.a.tab().Title = "YouTube"
	d.a.newTab(KPrivate, "", "", true)
	d.frames(2)
	d.click(slot*3.5, navY)
	if !d.a.tabsOpen {
		t.Fatal("the tabs button opens the tab grid")
	}
	d.frames(2)
	for _, v := range d.eng.views {
		if v.visible && !v.closed {
			t.Fatal("pages are hidden under the tab grid")
		}
	}
	d.shot("phone-tabs")
	// a card selects its tab and closes the grid
	d.click(16+40, in[0]+mBarH+60+60)
	if d.a.tabsOpen || d.a.cur != 0 {
		t.Fatalf("tapping the first card selects it: open=%v cur=%d", d.a.tabsOpen, d.a.cur)
	}

	// the menu is a full-screen sheet
	d.click(slot*4.5, navY)
	if !d.a.panel {
		t.Fatal("the menu button opens the menu")
	}
	d.frames(2)
	d.shot("phone-menu")

	// the system back button closes the sheet, then goes back in the page
	d.key(ui.KBack, false, false)
	if d.a.panel {
		t.Fatal("back closes the menu")
	}
	d.a.tab().CanBack = true
	d.key(ui.KBack, false, false)
	found := false
	for _, v := range d.eng.views {
		if v.backs > 0 {
			found = true
		}
	}
	if !found {
		t.Fatal("back goes back in the page")
	}

	// results on a phone: one column, under the address row
	d.a.newTab(KNormal, "", "", true)
	d.frame()
	d.a.addr.Set("tulips")
	d.a.st.Focus = ID("addr")
	d.frame()
	d.key(ui.KEnter, false, false)
	d.frames(3)
	if d.a.tab().search == nil {
		t.Fatal("a search opens Lite results")
	}
	d.shot("phone-results")
}

// The input method's edits (an Android keyboard composing a word) change
// the focused field in place instead of being typed again.
func TestIMEEdits(t *testing.T) {
	d := newPhone(t)
	d.frames(2)
	d.a.st.Focus = ID("addr")
	d.a.addr.Set("")
	d.frame()
	in := d.a.In
	for _, e := range []ui.Edit{{Start: 0, End: 0, Text: "t"}, {Start: 0, End: 1, Text: "tu"}, {Start: 0, End: 2, Text: "tul"}, {Start: 0, End: 3, Text: "tulip"}, {Start: 5, End: 5, Text: " "}} {
		in.Edits = append(in.Edits, e)
		d.frame()
	}
	if got := d.a.addr.Text(); got != "tulip " {
		t.Fatalf("composed text = %q, want %q", got, "tulip ")
	}
	if d.a.Editing() != d.a.addr {
		t.Fatal("the address field is reported as edited")
	}
}
