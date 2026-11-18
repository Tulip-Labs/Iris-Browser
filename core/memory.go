package core

// MemoryPlan is how Iris keeps the web engine's memory down: background
// tabs are hidden at once, put to sleep (suspended, low memory target) after
// SleepAfter seconds, and unloaded (the page closed, its address and title
// kept) after UnloadAfter seconds or when more than Live tabs hold a page.
type MemoryPlan struct {
	Live                    int
	SleepAfter, UnloadAfter float64
	// Low starts the engine in its low-end mode (fewer renderer processes).
	Low bool
	// BudgetMB is how much memory all the pages together may hold before the
	// balancer puts background tabs to sleep and then unloads them (0 = no budget).
	BudgetMB int
	// ReserveMB is the free system memory the balancer keeps (0 = not watched).
	ReserveMB int
}

// Plan picks the plan for a machine with totalMB of RAM and a profile
// ("saver", "balanced" or "speed").
//
// Memory goes back early: a background tab rests (its page closed, its
// address, title and scroll kept, so it comes back where it was) within a
// minute on the balanced plan, and only a few tabs hold a page at once.
func Plan(totalMB int, profile string) MemoryPlan {
	p := MemoryPlan{Live: 4, SleepAfter: 15, UnloadAfter: 60}
	switch {
	case totalMB > 0 && totalMB <= 4608:
		p = MemoryPlan{Live: 2, SleepAfter: 10, UnloadAfter: 30, Low: true}
	case totalMB > 0 && totalMB <= 8704:
		p.Live = 3
	}
	switch profile {
	case "saver":
		p.Live = 2
		p.SleepAfter, p.UnloadAfter = 5, 20
		p.Low = true
	case "speed":
		p.Live *= 2
		p.SleepAfter, p.UnloadAfter = 120, 600
	}
	// the share of memory the pages may take together
	share := 0.35
	switch profile {
	case "saver":
		share = 0.22
	case "speed":
		share = 0.55
	}
	if totalMB > 0 {
		p.BudgetMB = int(float64(totalMB) * share)
		p.ReserveMB = max(400, totalMB/12)
	}
	return p
}
