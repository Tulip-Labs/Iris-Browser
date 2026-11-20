package shell

import (
	"math"

	"iris/core"
	"iris/ui"
)

type loadState uint8

const (
	stLoading loadState = iota
	stDone
	stFailed
)

// Google AI Mode, read by a hidden page for the Ask AI panel. Searches typed
// in the address bar open AI Mode itself in the tab (core.Resolve); Iris has
// no results page of its own any more.

// askGoogleAI asks Google AI Mode (prompt) and streams its answer to update;
// done is true once the answer has stopped changing.
//
// To be dependable it finishes as soon as Google marks the answer complete (or
// the text stops changing), keeps a partial answer when time runs out, and
// tries once more on a fresh page when nothing came back.
func (a *App) askGoogleAI(w *worker, tag, prompt, question string, timeout float64, update func(r core.AIResult, done bool)) {
	a.askGoogleAITry(w, tag, prompt, timeout, update, 0)
}

func (a *App) askGoogleAITry(w *worker, tag, prompt string, timeout float64, update func(r core.AIResult, done bool), attempt int) {
	last, stable := "", 0
	var best core.AIResult
	a.enqueue(w, &job{tag: tag, url: core.ModeAI.URL(prompt), script: core.AIScript, timeout: timeout, every: 0.6,
		handle: func(js string) bool {
			r := core.ParseAI(js, core.AIPrompt(prompt))
			if r.Captcha {
				update(r, true)
				return true
			}
			if len(r.Text) >= len(best.Text) || len(r.Sources) > len(best.Sources) {
				best = r
			}
			if r.Text != "" && r.Text == last && !r.Busy {
				stable++
			} else {
				stable = 0
			}
			last = r.Text
			need := 3
			if len(r.Text) > 400 {
				need = 2
			}
			done := r.Text != "" && (r.Done && !r.Busy && stable >= 1 || stable >= need)
			update(r, done)
			return done
		},
		fail: func() {
			switch {
			case best.Text != "":
				update(best, true) // keep what was written
			case attempt == 0:
				a.askGoogleAITry(w, tag, prompt, timeout, update, 1)
			default:
				update(core.AIResult{}, true)
			}
		}})
}

func shimmer(a *App, r ui.Rect, rad float32) {
	th := a.u.Th
	a.u.Redraw = true
	k := float32(0.5 + 0.5*math.Sin(a.now()*3+float64(r.Y)*0.02))
	ui.FillRound(a.u.G, r, rad, th.Ink.Alpha(0.05+0.04*k))
}

func (a *App) resultNote(r ui.Rect, text, action string, do func()) float32 {
	u, g, th := &a.u, a.u.G, a.u.Th
	y := r.Y
	for _, ln := range wrap(g, text, ui.FBody, r.W) {
		g.Text(ln, r.X, y+16, ui.FBody, th.OnSurfaceVariant)
		y += 22
	}
	if action != "" {
		bw := g.Measure(action, ui.FBodyBold) + 40
		if u.Button(ui.Id("note/"+action), ui.Rect{X: r.X, Y: y + 8, W: bw, H: 36}, action, ui.ButtonOpt{}) {
			do()
		}
		y += 52
	}
	return y
}

// ease moves pos toward to at a calm speed; true while still moving.
func ease(pos *float32, to, dt float32) bool {
	d := to - *pos
	if absf(d) < 0.002 {
		*pos = to
		return false
	}
	*pos += d * min(1, dt*11)
	return true
}
