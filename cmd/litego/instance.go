package main

import (
	"bufio"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// One Lite Go at a time: the running copy listens on the loopback address; a
// new launch passes it the addresses to open (with a secret from the user's own
// settings folder) and exits.

type instanceFile struct {
	Port  int    `json:"port"`
	PID   int    `json:"pid"`
	Token string `json:"token"`
}

func instancePath(conf string) string { return filepath.Join(conf, "instance.json") }

// running reports whether a Lite Go answers on its port.
func running(conf string) bool {
	b, err := os.ReadFile(instancePath(conf))
	if err != nil {
		return false
	}
	var f instanceFile
	if json.Unmarshal(b, &f) != nil || f.Port == 0 {
		return false
	}
	c, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", itoa(f.Port)), 300*time.Millisecond)
	if err != nil {
		return false
	}
	c.Close()
	return true
}

// handOff gives urls to a running Lite Go; false when none answers.
func handOff(conf string, urls []string) bool {
	b, err := os.ReadFile(instancePath(conf))
	if err != nil {
		return false
	}
	var f instanceFile
	if json.Unmarshal(b, &f) != nil || f.Port == 0 {
		return false
	}
	c, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", itoa(f.Port)), 300*time.Millisecond)
	if err != nil {
		return false
	}
	defer c.Close()
	allowForeground(f.PID) // this launch came from a click: let the window come to the front
	_ = c.SetDeadline(time.Now().Add(2 * time.Second))
	msg, _ := json.Marshal(urls)
	if _, err := c.Write([]byte(f.Token + "\n" + string(msg) + "\n")); err != nil {
		return false
	}
	reply, err := bufio.NewReader(c).ReadString('\n')
	return err == nil && strings.TrimSpace(reply) == "ok"
}

// listen becomes the running Lite Go; each request is the list of addresses to open.
func listen(conf string) <-chan []string {
	out := make(chan []string, 4)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return out // still run, just without hand-off
	}
	tok := make([]byte, 16)
	_, _ = rand.Read(tok)
	f := instanceFile{Port: ln.Addr().(*net.TCPAddr).Port, PID: os.Getpid(), Token: hex.EncodeToString(tok)}
	b, _ := json.Marshal(f)
	_ = os.WriteFile(instancePath(conf), b, 0o600)
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				_ = c.SetDeadline(time.Now().Add(2 * time.Second))
				rd := bufio.NewReader(c)
				tok, err := rd.ReadString('\n')
				if err != nil || strings.TrimSpace(tok) != f.Token {
					return
				}
				line, _ := rd.ReadString('\n')
				var urls []string
				_ = json.Unmarshal([]byte(line), &urls)
				_, _ = c.Write([]byte("ok\n"))
				out <- urls
			}(c)
		}
	}()
	return out
}

func itoa(n int) string {
	b, _ := json.Marshal(n)
	return string(b)
}
