package main

import (
	"bufio"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

func openPath(p string)   { _ = exec.Command("xdg-open", p).Start() }
func revealPath(p string) { _ = exec.Command("xdg-open", filepath.Dir(p)).Start() }

// pickFiles asks for files with the desktop's own file box (zenity on GNOME
// and most others, kdialog on KDE). It waits for the reader.
func pickFiles() []string {
	out, err := exec.Command("zenity", "--file-selection", "--multiple", "--separator=\n", "--title=Send to the phone").Output()
	if err != nil {
		if _, missing := exec.LookPath("zenity"); missing == nil {
			return nil // the reader closed the box
		}
		out, err = exec.Command("kdialog", "--getopenfilename", "--multiple", "--separate-output", "--title", "Send to the phone").Output()
		if err != nil {
			return nil
		}
	}
	var files []string
	for _, f := range strings.Split(string(out), "\n") {
		if f = strings.TrimSpace(f); f != "" {
			files = append(files, f)
		}
	}
	return files
}

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
