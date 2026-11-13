//go:build !windows

package main

import (
	"bufio"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

func focusWindow(uintptr) {}
func allowForeground(int) {}
func setStartup(bool)     {}

func openPath(p string)    { _ = exec.Command("xdg-open", p).Start() }
func revealPath(p string)  { _ = exec.Command("xdg-open", filepath.Dir(p)).Start() }
func packaged(string) bool { return false }

func totalMB() int { return meminfo("MemTotal:") }
func freeMB() int  { return meminfo("MemAvailable:") }

func meminfo(key string) int {
	f, err := os.Open("/proc/meminfo")
	if err != nil {
		return 0
	}
	defer f.Close()
	s := bufio.NewScanner(f)
	for s.Scan() {
		if fs := strings.Fields(s.Text()); len(fs) >= 2 && fs[0] == key {
			kb, _ := strconv.Atoi(fs[1])
			return kb >> 10
		}
	}
	return 0
}
