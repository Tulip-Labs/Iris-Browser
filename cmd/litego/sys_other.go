//go:build !windows

package main

import (
	"bufio"
	"os"
	"strconv"
	"strings"
)

func focusWindow(uintptr) {}
func allowForeground(int) {}
func setStartup(bool)     {}

func totalMB() int {
	f, err := os.Open("/proc/meminfo")
	if err != nil {
		return 0
	}
	defer f.Close()
	s := bufio.NewScanner(f)
	for s.Scan() {
		if fs := strings.Fields(s.Text()); len(fs) >= 2 && fs[0] == "MemTotal:" {
			kb, _ := strconv.Atoi(fs[1])
			return kb >> 10
		}
	}
	return 0
}
