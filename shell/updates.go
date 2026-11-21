package shell

import (
	"context"
	"time"

	"iris/update"
)

// Updates: Flatpak, Snap or Nix, which installed Iris, also update it. Iris
// only asks GitHub now and then whether a newer version is out, and says so.

type updater struct {
	busy    bool
	status  string
	latest  string // the newest version seen
	checked bool   // checked this session
}

const updateEvery = 6 * 3600 // seconds between automatic checks

var kindLabels = map[update.Kind]string{
	update.KindFlatpak: "as a Flatpak",
	update.KindSnap:    "as a Snap",
	update.KindNix:     "with Nix",
	update.KindDev:     "from source",
}

func (a *App) updateKind() update.Kind { return update.Kind(a.cfg.UpdateKind) }

// updateTick checks now and then (from tick); a copy built from source is
// not checked by itself.
func (a *App) updateTick() {
	k := a.updateKind()
	if k == "" || k == update.KindDev || a.upd.busy || a.now() < 20 {
		return
	}
	if time.Now().Unix()-a.set.UpdateChecked < updateEvery {
		return
	}
	a.checkUpdate(false)
}

// checkUpdate asks GitHub for the latest release; asked is true when the
// reader pressed the button.
func (a *App) checkUpdate(asked bool) {
	if a.upd.busy {
		return
	}
	a.upd.busy, a.upd.status = true, "Checking for updates…"
	k, cur := a.updateKind(), a.cfg.Version
	go func() {
		r, err := update.Latest(context.Background())
		a.post(func() {
			a.upd.busy = false
			a.set.UpdateChecked = time.Now().Unix()
			a.set.Save()
			a.upd.checked = true
			if err != nil {
				a.upd.status = "Could not check for updates: " + err.Error()
				return
			}
			a.upd.latest = r.Version()
			if !update.Newer(r.Version(), cur) {
				a.upd.status = "Iris " + cur + " is the latest version."
				return
			}
			a.upd.status = "Iris " + r.Version() + " is out. It comes through " + k.Managed() + "."
			if !asked {
				a.bar = infobar{text: a.upd.status, until: a.now() + 10}
				a.h.Invalidate()
			}
		})
	}()
}
