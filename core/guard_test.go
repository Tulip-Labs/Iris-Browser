package core

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/binary"
	"hash/crc32"
	"image"
	"image/png"
	"net"
	"os"
	"path/filepath"
	"testing"
)

func TestPrivateHostsAreReal(t *testing.T) {
	for _, u := range []string{"http://localhost/", "http://localhost:8080/", "http://app.localhost/", "http://127.0.0.1/",
		"http://10.0.0.1/", "http://192.168.1.1/", "http://172.16.0.1/", "http://[::1]:3000/", "http://[fd00::1]/"} {
		if !IsPrivateHost(u) || HTTPSUpgrade(u) != "" {
			t.Errorf("%s is a local address", u)
		}
	}
	// names that only start like a local address are public sites: HTTPS-only
	// applies and the address checks run
	for _, u := range []string{"http://10.example.com/", "http://localhost.evil.net/", "http://192.168.evil.net/",
		"http://127.0.0.1.nip.example/", "http://172.20.bank-login.com/"} {
		if IsPrivateHost(u) {
			t.Errorf("%s was taken for a local address", u)
		}
		if HTTPSUpgrade(u) == "" {
			t.Errorf("%s was not upgraded to HTTPS", u)
		}
	}
	for in, want := range map[string]string{
		"10.example.com":     "https://10.example.com",
		"localhost.evil.net": "https://localhost.evil.net",
		"192.168.1.1:8080/x": "http://192.168.1.1:8080/x",
		"[::1]:8080":         "http://[::1]:8080",
		"localhost?q=1":      "http://localhost?q=1",
	} {
		if got := URLFor(in); got != want {
			t.Errorf("URLFor(%q) = %q, want %q", in, got, want)
		}
	}
	// the address checks run on such names (here: a name in front of the site)
	if Risk("http://paypal.com@10.example.com/") == "" {
		t.Error("risk checks skipped for a public name that starts like a local address")
	}
}

func TestPublicIP(t *testing.T) {
	for _, s := range []string{"8.8.8.8", "1.1.1.1", "2606:4700::1111", "142.250.1.1"} {
		if !PublicIP(net.ParseIP(s)) {
			t.Errorf("%s is public", s)
		}
	}
	for _, s := range []string{"127.0.0.1", "10.1.2.3", "192.168.0.1", "172.31.255.255", "169.254.169.254", "0.0.0.0",
		"100.64.0.1", "224.0.0.1", "255.255.255.255", "::1", "::", "fe80::1", "fd12::1", "::ffff:127.0.0.1", "::ffff:10.0.0.1"} {
		if PublicIP(net.ParseIP(s)) {
			t.Errorf("%s was taken for a public address", s)
		}
	}
}

func TestImageBomb(t *testing.T) {
	// a picture that claims 20000 x 20000 pixels (1.6 GB once decoded) in a
	// file of a few kilobytes is refused before it is decoded
	src := "data:image/png;base64," + base64.StdEncoding.EncodeToString(pngHeader(20000, 20000))
	if _, err := FetchImage(context.Background(), src, 200); err == nil || err.Error() != "picture too large" {
		t.Fatalf("a 400-megapixel picture was not refused for its size: %v", err)
	}
	var buf bytes.Buffer
	png.Encode(&buf, image.NewRGBA(image.Rect(0, 0, 400, 300)))
	img, err := FetchImage(context.Background(), "data:image/png;base64,"+base64.StdEncoding.EncodeToString(buf.Bytes()), 200)
	if err != nil || img.Bounds().Dx() != 200 || img.Bounds().Dy() != 150 {
		t.Fatalf("a normal picture: %v %v", img, err)
	}
	if _, err := FetchImage(context.Background(), "data:image/png,not-base64", 200); err == nil {
		t.Fatal("a data address without base64 was decoded")
	}
}

// pngHeader is the start of a PNG that claims w x h pixels: enough for a
// decoder to read its size, without making the picture.
func pngHeader(w, h uint32) []byte {
	ihdr := make([]byte, 0, 17)
	ihdr = append(ihdr, "IHDR"...)
	ihdr = binary.BigEndian.AppendUint32(ihdr, w)
	ihdr = binary.BigEndian.AppendUint32(ihdr, h)
	ihdr = append(ihdr, 8, 0, 0, 0, 0) // 8-bit grey
	b := []byte("\x89PNG\r\n\x1a\n")
	b = binary.BigEndian.AppendUint32(b, 13)
	b = append(b, ihdr...)
	b = binary.BigEndian.AppendUint32(b, crc32.ChecksumIEEE(ihdr))
	return b
}

func TestClientRefusesLocal(t *testing.T) {
	ln, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Skip(err)
	}
	defer ln.Close()
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			c.Write([]byte("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"))
			c.Close()
		}
	}()
	if _, err := get(context.Background(), "http://"+ln.Addr().String()+"/", 1<<10); err == nil {
		t.Fatal("the thumbnail client reached this computer")
	}
}

func TestSettingsDamaged(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "settings.json")
	os.WriteFile(p, []byte(`{"theme": "dark", "window": {"W": 99999999, "H": -4}, "restore": `), 0o600)
	s := LoadSettings(dir)
	if s.Window.W != 0 || s.Window.H != 0 {
		t.Errorf("window %+v kept from a damaged file", s.Window)
	}
	if _, err := os.Stat(p + ".damaged"); err != nil {
		t.Error("the damaged file was not kept aside")
	}
	s.Theme = "light"
	s.Flush()
	if LoadSettings(dir).Theme != "light" {
		t.Error("settings not written")
	}
}
