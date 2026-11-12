package shell

import (
	"context"
	"image"
	"time"

	"litego/core"
	"litego/webview"
)

// A worker is a hidden page that reads Google for Lite results and for the AI
// panel. Jobs run one after another; the page is closed when it has been idle
// for a while, so it only costs memory while it is useful.
type worker struct {
	private bool
	view    webview.View
	making  bool
	loaded  bool
	queue   []*job
	cur     *job
	idle    float64 // when the last job ended
	polling bool
}

type job struct {
	url, script string
	tag         string
	timeout     float64
	// handle receives each script result; it returns true when the job is done.
	handle  func(js string) bool
	fail    func()
	start   float64
	lastRun float64
	running bool
	every   float64
}

// workerFor returns the worker for private tabs or not; ai picks the one that
// talks to AI Mode, so answers are written while the links load.
func (a *App) workerFor(private, ai bool) *worker {
	i := 0
	if private {
		i = 1
	}
	if ai {
		i += 2
	}
	if a.workers[i] == nil {
		a.workers[i] = &worker{private: private}
	}
	return a.workers[i]
}

// enqueue adds a job; it starts on the next frame.
func (a *App) enqueue(w *worker, j *job) {
	if j.every == 0 {
		j.every = 0.6
	}
	w.queue = append(w.queue, j)
	a.h.Invalidate()
}

// cancelJobs drops waiting jobs that match drop (the current one ends at its timeout).
func (w *worker) cancel(drop func(*job) bool) {
	keep := w.queue[:0]
	for _, j := range w.queue {
		if !drop(j) {
			keep = append(keep, j)
		}
	}
	w.queue = keep
}

// runWorkers advances every worker's jobs (called each frame).
func (a *App) runWorkers() {
	now := a.now()
	for _, w := range a.workers {
		if w == nil {
			continue
		}
		a.runWorker(w, now)
	}
}

func (a *App) runWorker(w *worker, now float64) {
	if a.eng == nil || !a.ready {
		for _, j := range w.queue {
			if j.fail != nil {
				j.fail()
			}
		}
		w.queue = nil
		return
	}
	if w.cur == nil {
		if len(w.queue) == 0 {
			if w.view != nil && now-w.idle > 30 {
				v := w.view
				a.web(v.Close)
				w.view = nil
			}
			return
		}
		w.cur, w.queue = w.queue[0], w.queue[1:]
		w.cur.start = now
		w.loaded = false
		if w.view != nil {
			v, u := w.view, w.cur.url
			a.web(func() { v.Navigate(u) })
		}
	}
	if w.view == nil {
		if !w.making {
			w.making = true
			o := webview.Options{}
			if w.private {
				o = webview.Options{Profile: "private", Private: true}
			}
			eng := a.eng
			ev := webview.Events{Loading: func(l bool) {
				a.post(func() {
					if !l {
						w.loaded = true
					}
				})
			}}
			a.web(func() {
				eng.NewView(o, ev, func(v webview.View, err error) {
					if err == nil {
						v.SetVisible(false)
						v.SetBounds(0, 0, 1280, 900) // laid out like a real window, never shown
					}
					a.post(func() {
						w.making = false
						if err != nil {
							if w.cur != nil && w.cur.fail != nil {
								w.cur.fail()
							}
							w.cur = nil
							return
						}
						w.view = v
						if w.cur != nil {
							u := w.cur.url
							a.web(func() { v.Navigate(u) })
						}
					})
				})
			})
		}
		a.later(0.3)
		return
	}
	j := w.cur
	if now-j.start > j.timeout {
		if j.fail != nil {
			j.fail()
		}
		w.cur, w.idle = nil, now
		a.later(0.05)
		return
	}
	if w.loaded && !j.running && now-j.lastRun >= j.every {
		j.running, j.lastRun = true, now
		v, script := w.view, j.script
		a.web(func() {
			v.Run(script, func(res string) {
				a.post(func() {
					j.running = false
					if w.cur != j {
						return
					}
					if j.handle(res) {
						w.cur, w.idle = nil, a.now()
					}
				})
			})
		})
	}
	a.later(j.every)
}

// later asks for a frame after d seconds (workers poll without busy frames).
func (a *App) later(d float64) {
	if a.wakeAt > 0 && a.wakeAt <= a.now()+d {
		return
	}
	a.wakeAt = a.now() + d
	h := a.h
	time.AfterFunc(time.Duration(d*float64(time.Second)), func() { h.Invalidate() })
}

// ---- thumbnails ----

type thumb struct {
	img     image.Image
	loading bool
	failed  bool
	used    float64
}

// thumbFor returns a loaded thumbnail, starting its download the first time.
func (a *App) thumbFor(src string) image.Image {
	if src == "" {
		return nil
	}
	t := a.thumbs[src]
	if t == nil {
		if len(a.thumbs) > 80 {
			a.trimThumbs(15)
		}
		t = &thumb{loading: true}
		a.thumbs[src] = t
		fetch := a.fetchImage
		go func() {
			a.thumbSem <- struct{}{}
			defer func() { <-a.thumbSem }()
			ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
			defer cancel()
			img, err := fetch(ctx, src, 320)
			a.post(func() {
				t.loading = false
				t.img, t.failed = img, err != nil
			})
		}()
	}
	t.used = a.now()
	return t.img
}

// trimThumbs lets go of pictures not drawn for the last age seconds.
func (a *App) trimThumbs(age float64) {
	cut := a.now() - age
	for k, t := range a.thumbs {
		if !t.loading && t.used < cut {
			delete(a.thumbs, k)
		}
	}
}

var _ = core.FetchImage
