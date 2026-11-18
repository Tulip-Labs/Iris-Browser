//go:build linux && webkit

package main

import (
	"context"
	"encoding/json"
	"math"
	"os"
	"os/exec"
	"strconv"
	"time"
)

// GTK 3 draws only at whole scales (1, 2, 3). On a screen scaled by a
// fraction (1.25, 1.5, 1.75) the compositor tells it 1, and then stretches
// the window up: everything, Iris's own bars and the pages, comes out
// blocky. Firefox and the Android app avoid it with Wayland's fractional
// scaling, which GTK 3 lacks. So Iris asks the compositor for the screen's
// real scale and, when it is a fraction, draws at the next whole scale; the
// compositor then shrinks the window a little, which stays sharp.
// GDK_SCALE set by hand always wins.
func init() {
	if os.Getenv("GDK_SCALE") != "" || os.Getenv("WAYLAND_DISPLAY") == "" {
		return
	}
	if s := sharpScale(outputScales()); s > 1 {
		os.Setenv("GDK_SCALE", strconv.Itoa(s))
	}
}

// sharpScale is the whole scale to draw at for the screens' scales: the
// largest one rounded up, when any is a fraction above 1; 0 when GTK's own
// scale is already right.
func sharpScale(scales []float64) int {
	top, frac := 0.0, false
	for _, s := range scales {
		if s > top {
			top = s
		}
		if s > 1 && math.Abs(s-math.Round(s)) > 0.01 {
			frac = true
		}
	}
	if !frac {
		return 0
	}
	return int(math.Ceil(top - 0.01))
}

// outputScales asks niri, Sway or Hyprland for the scale of each screen.
func outputScales() []float64 {
	run := func(name string, args ...string) []byte {
		if _, err := exec.LookPath(name); err != nil {
			return nil
		}
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		out, err := exec.CommandContext(ctx, name, args...).Output()
		if err != nil {
			return nil
		}
		return out
	}
	if os.Getenv("NIRI_SOCKET") != "" {
		if s := niriScales(run("niri", "msg", "--json", "outputs")); len(s) > 0 {
			return s
		}
	}
	if os.Getenv("SWAYSOCK") != "" {
		if s := listScales(run("swaymsg", "-t", "get_outputs", "-r")); len(s) > 0 {
			return s
		}
	}
	if os.Getenv("HYPRLAND_INSTANCE_SIGNATURE") != "" {
		if s := listScales(run("hyprctl", "-j", "monitors")); len(s) > 0 {
			return s
		}
	}
	return nil
}

// niriScales reads `niri msg --json outputs`: name -> {logical: {scale}}.
func niriScales(b []byte) []float64 {
	var outs map[string]struct {
		Logical *struct {
			Scale float64 `json:"scale"`
		} `json:"logical"`
	}
	if json.Unmarshal(b, &outs) != nil {
		return nil
	}
	var s []float64
	for _, o := range outs {
		if o.Logical != nil && o.Logical.Scale > 0 {
			s = append(s, o.Logical.Scale)
		}
	}
	return s
}

// listScales reads Sway's and Hyprland's lists: [{scale}].
func listScales(b []byte) []float64 {
	var outs []struct {
		Scale  float64 `json:"scale"`
		Active *bool   `json:"active"`
	}
	if json.Unmarshal(b, &outs) != nil {
		return nil
	}
	var s []float64
	for _, o := range outs {
		if o.Scale > 0 && (o.Active == nil || *o.Active) {
			s = append(s, o.Scale)
		}
	}
	return s
}
