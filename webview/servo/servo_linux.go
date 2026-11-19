//go:build linux && webkit && servo

package servo

// The Servo engine on Linux: the GTK side. The engine itself (servo.go) is
// shared with Windows; this file is only what Linux does differently.

/*
#cgo pkg-config: gtk4
#cgo LDFLAGS: -L${SRCDIR}/lib -lirisservo -Wl,-rpath,$ORIGIN
#include <stdint.h>
#include <stdlib.h>
#include "irisservo.h"

int lsvStart(uintptr_t view);
int lsvOpen(uint64_t id, const char *url);
void lsvClose(uint64_t id);
void lsvBounds(uint64_t id, int x, int y, int w, int h);
void lsvShow(uint64_t id, int on);
void lsvFocus(uint64_t id);
void lsvWake(void);
void lsvTicks(void);
*/
import "C"

import (
	"bufio"
	"os"
	"strconv"
	"strings"
)

// svPlatformStart is nothing extra on Linux: lsvStart attaches Servo to the
// GTK window.
func svPlatformStart(window uintptr) {}

// svPlatformTicks starts the memory check (lsvGoTick, every 10 seconds).
func svPlatformTicks() { C.lsvTicks() }

// svRssMB is this process's resident memory.
func svRssMB() float64 {
	b, err := os.ReadFile("/proc/self/statm")
	if err != nil {
		return 0
	}
	f := strings.Fields(string(b))
	if len(f) < 2 {
		return 0
	}
	pages, _ := strconv.ParseFloat(f[1], 64)
	return pages * float64(os.Getpagesize()) / (1 << 20)
}

// svTotalMemMB is the computer's memory.
func svTotalMemMB() float64 {
	total := 8192.0
	if f, err := os.Open("/proc/meminfo"); err == nil {
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			if fs := strings.Fields(sc.Text()); len(fs) >= 2 && fs[0] == "MemTotal:" {
				kb, _ := strconv.ParseFloat(fs[1], 64)
				total = kb / 1024
			}
		}
		f.Close()
	}
	return total
}
