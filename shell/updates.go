package shell

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"litego/update"
)

// Updates from the GitHub releases. Copies in the home folder and Flatpak
// bundles update by themselves in the background; packages (.deb, .rpm) and
// the Windows installer are downloaded in the background and installed with
// one click, since they ask for a password or show the installer.

type updater struct {
	busy    bool
	status  string
	latest  string  // the newest version seen
	ready   string  // a downloaded package waiting for its click
	shown   float64 // when the last bar was shown
	checked bool    // checked this session
}

const updateEvery = 6 * 3600 // seconds between automatic checks

var kindLabels = map[update.Kind]string{
	update.KindUser:     "in your home folder (.tar.gz)",
	update.KindDeb:      "as a .deb package",
	update.KindRPM:      "as an .rpm package",
	update.KindOSTree:   "layered on Fedora Atomic (rpm-ostree)",
	update.KindArch:     "from the AUR",
	update.KindFlatpak:  "as a Flatpak bundle",
	update.KindFlathub:  "as a Flatpak from a remote",
	update.KindNix:      "with Nix",
	update.KindSetup:    "with Lite Go Setup",
	update.KindStore:    "from the Microsoft Store",
	update.KindPortable: "as a portable copy",
	update.KindDev:      "from source",
}

func (a *App) updateKind() update.Kind { return update.Kind(a.cfg.UpdateKind) }

// updateTick checks now and then (from tick).
func (a *App) updateTick() {
	k := a.updateKind()
	if k == "" || !k.CanSelf() || !a.set.AutoUpdate || a.upd.busy || a.now() < 20 {
		return
	}
	if time.Now().Unix()-a.set.UpdateChecked < updateEvery {
		return
	}
	a.checkUpdate(false)
}

// checkUpdate asks GitHub for the latest release; asked is true when the
// reader pressed the button (then a package installs right away).
func (a *App) checkUpdate(asked bool) {
	if a.upd.busy {
		return
	}
	a.upd.busy, a.upd.status = true, "Checking for updates…"
	k, cur := a.updateKind(), a.cfg.Version
	go func() {
		r, err := update.Latest(context.Background())
		a.post(func() {
			a.set.UpdateChecked = time.Now().Unix()
			a.set.Save()
			a.upd.checked = true
			if err != nil {
				a.upd.busy, a.upd.status = false, "Could not check for updates: "+err.Error()
				return
			}
			a.upd.latest = r.Version()
			if !update.Newer(r.Version(), cur) {
				a.upd.busy, a.upd.status = false, "Lite Go "+cur+" is the latest version."
				return
			}
			if !k.CanSelf() {
				a.upd.busy, a.upd.status = false, "Lite Go "+r.Version()+" is out. Updates for this copy come from "+k.Managed()+"."
				return
			}
			a.fetchUpdate(r, k, asked)
		})
	}()
}

func updateDir() string {
	d, err := os.UserCacheDir()
	if err != nil {
		d = os.TempDir()
	}
	return filepath.Join(d, "Lite Go", "updates")
}

func (a *App) fetchUpdate(r update.Release, k update.Kind, asked bool) {
	ver := r.Version()
	a.upd.status = "Downloading Lite Go " + ver + "…"
	silent := k == update.KindUser || k == update.KindFlatpak
	go func() {
		dir := updateDir()
		os.RemoveAll(dir) // what an earlier update left
		p, err := update.Fetch(context.Background(), r, k, dir, func(f float32) {
			a.post(func() { a.upd.status = "Downloading Lite Go " + ver + "… " + pct(f) })
		})
		a.post(func() {
			if err != nil {
				a.upd.busy, a.upd.status = false, "The update could not be downloaded: "+err.Error()
				return
			}
			if silent || asked {
				a.installUpdate(k, p, ver)
				return
			}
			// a package: one click, then the system asks for the password
			a.upd.busy, a.upd.ready = false, p
			a.upd.status = "Lite Go " + ver + " is downloaded and ready to install."
			a.bar = infobar{text: "Lite Go " + ver + " is ready to install.", action: "Install", do: func() { a.installUpdate(k, p, ver) },
				action2: "Later", do2: func() {}}
			a.h.Invalidate()
		})
	}()
}

func (a *App) installUpdate(k update.Kind, path, ver string) {
	a.upd.busy, a.upd.ready = true, ""
	a.upd.status = "Installing Lite Go " + ver + "…"
	go func() {
		res, err := update.Install(context.Background(), k, path)
		a.post(func() {
			a.upd.busy = false
			if err != nil {
				a.upd.status = "The update was not installed: " + err.Error()
				a.bar = infobar{warn: true, text: a.upd.status, until: a.now() + 8}
				return
			}
			if !res.Restart {
				a.upd.status = "Lite Go Setup is installing " + ver + "."
				return
			}
			a.upd.status = "Lite Go " + ver + " is installed. It opens with the next start."
			a.bar = infobar{text: "Lite Go " + ver + " is installed.", action: "Restart now", do: func() {
				if update.Restart() == nil {
					a.h.Quit()
				}
			}, action2: "Later", do2: func() {}}
			a.h.Invalidate()
		})
	}()
}

func pct(f float32) string {
	n := int(f*100 + 0.5)
	return strconv.Itoa(n) + "%"
}
