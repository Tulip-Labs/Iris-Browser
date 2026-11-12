package core

// MemoryPlan is how Lite Go keeps the web engine's memory down: background
// tabs are hidden at once, put to sleep (suspended, low memory target) after
// SleepAfter seconds, and unloaded (the page closed, its address and title
// kept) after UnloadAfter seconds or when more than Live tabs hold a page.
type MemoryPlan struct {
	Live                    int
	SleepAfter, UnloadAfter float64
	// Low starts the engine in its low-end mode (fewer renderer processes).
	Low bool
}

// Plan picks the plan for a machine with totalMB of RAM and a profile
// ("saver", "balanced" or "speed").
func Plan(totalMB int, profile string) MemoryPlan {
	p := MemoryPlan{Live: 12, SleepAfter: 120, UnloadAfter: 900}
	switch {
	case totalMB > 0 && totalMB <= 4608:
		p = MemoryPlan{Live: 4, SleepAfter: 60, UnloadAfter: 600, Low: true}
	case totalMB > 0 && totalMB <= 8704:
		p.Live = 6
	}
	switch profile {
	case "saver":
		p.Live = max(2, p.Live/2)
		p.SleepAfter, p.UnloadAfter = 30, 300
		p.Low = true
	case "speed":
		p.Live *= 2
		p.SleepAfter, p.UnloadAfter = 600, 3600
	}
	return p
}
