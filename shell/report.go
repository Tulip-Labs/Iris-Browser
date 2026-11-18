package shell

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"runtime/pprof"
	"time"
)

// memoryReport writes what Lite Go's own process holds (and a heap profile) to
// the settings folder, to send along with a memory question.
func (a *App) memoryReport() (string, error) {
	dir := a.cfg.DataDir
	if dir == "" {
		dir = os.TempDir()
	}
	runtime.GC()
	var m runtime.MemStats
	runtime.ReadMemStats(&m)
	live, asleep, unloaded := a.Counts()
	mb := func(b uint64) string { return fmt.Sprintf("%.1f MB", float64(b)/(1<<20)) }
	txt := fmt.Sprintf(`Iris %s memory report, %s
Process (Windows private bytes): %.1f MB
Pages (WebView2 processes): %.1f MB
Go heap in use: %s  idle: %s  released: %s  total from Windows: %s
Goroutines: %d  GC cycles: %d
Tabs: %d awake, %d asleep, %d unloaded  Pictures cached: %d
`, a.cfg.Version, time.Now().Format(time.RFC1123), a.appMB, a.memMB,
		mb(m.HeapInuse), mb(m.HeapIdle), mb(m.HeapReleased), mb(m.Sys),
		runtime.NumGoroutine(), m.NumGC, live, asleep, unloaded, len(a.thumbs))
	p := filepath.Join(dir, "memory-report.txt")
	if err := os.WriteFile(p, []byte(txt), 0o644); err != nil {
		return "", err
	}
	if f, err := os.Create(filepath.Join(dir, "memory-heap.pprof")); err == nil {
		_ = pprof.WriteHeapProfile(f)
		f.Close()
	}
	return p, nil
}
