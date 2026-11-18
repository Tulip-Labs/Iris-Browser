//go:build linux && webkit

package main

import "testing"

func TestSharpScale(t *testing.T) {
	for _, c := range []struct {
		in   []float64
		want int
	}{
		{nil, 0}, {[]float64{1}, 0}, {[]float64{2}, 0}, {[]float64{1.25}, 2}, {[]float64{1.5}, 2},
		{[]float64{1, 1.75}, 2}, {[]float64{2.5}, 3}, {[]float64{0.75}, 0}, {[]float64{1.0000001}, 0},
	} {
		if got := sharpScale(c.in); got != c.want {
			t.Errorf("sharpScale(%v) = %d, want %d", c.in, got, c.want)
		}
	}
	n := niriScales([]byte(`{"eDP-1":{"name":"eDP-1","logical":{"x":0,"y":0,"width":1536,"height":864,"scale":1.25,"transform":"Normal"}},"HDMI-A-1":{"logical":null}}`))
	if len(n) != 1 || n[0] != 1.25 {
		t.Fatalf("niri: %v", n)
	}
	if s := listScales([]byte(`[{"name":"eDP-1","scale":1.5,"active":true},{"name":"DP-1","scale":1,"active":false}]`)); len(s) != 1 || s[0] != 1.5 {
		t.Fatalf("sway: %v", s)
	}
}
