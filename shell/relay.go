package shell

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"
)

// The video relay. Iris's Chromium on Linux has no H.264, H.265 or AAC (the
// free builds leave them out, and they are compiled into the engine, so no
// package can add them), and some sites (LinkedIn, X, many news sites) send
// only those. When such a video cannot play, the page script
// (core.H264Script) points it here instead, and the relay plays it through
// the system's own decoder: ffmpeg (or GStreamer) reads the original,
// decoding on the graphics chip where it can (VA-API), and turns it into WebM
// (VP9 on the graphics chip when it can encode it, else VP8; Opus for sound),
// which Chromium plays.
//
// It listens on the loopback address only and answers only addresses
// carrying its key. Every page can read that key (it is in the page's
// script), so the relay also answers only a video or audio element's own
// request (Sec-Fetch-Dest, which page scripts cannot set), sends nothing
// scripts may read (no CORS), and fetches only public http and https
// addresses: never the computer itself or its local network.

type relay struct {
	base string // http://127.0.0.1:port/v?k=key&u=
	key  string
	busy chan struct{} // at most two conversions at once
	once sync.Once
}

// startRelay starts the relay; it returns nil when the system has no tool
// to convert with.
func startRelay() *relay {
	if _, err := exec.LookPath("ffmpeg"); err != nil {
		if _, err := exec.LookPath("gst-launch-1.0"); err != nil {
			return nil
		}
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil
	}
	b := make([]byte, 16)
	rand.Read(b)
	r := &relay{key: hex.EncodeToString(b), busy: make(chan struct{}, 2)}
	r.base = "http://" + ln.Addr().String() + "/v?k=" + r.key + "&u="
	srv := &http.Server{Handler: r, ReadHeaderTimeout: 5 * time.Second}
	go srv.Serve(ln)
	go hwEncoder() // look for the graphics chip's encoder ahead of the first video
	return r
}

// mediaRequest says whether the request comes from a video or audio element
// (browsers set Sec-Fetch-Dest themselves; a page's fetch() says "empty").
func mediaRequest(q *http.Request) bool {
	switch q.Header.Get("Sec-Fetch-Dest") {
	case "video", "audio":
		return true
	}
	return false
}

// publicURL checks a video's address: http or https, a host that is not this
// computer or its local network, and nothing the converters would read as
// more than an address.
func publicURL(src string) (*url.URL, bool) {
	pu, err := url.Parse(src)
	if err != nil || (pu.Scheme != "https" && pu.Scheme != "http") || pu.Host == "" || pu.User != nil {
		return nil, false
	}
	if strings.ContainsAny(src, "\"\\\r\n\t <>|") {
		return nil, false
	}
	host := pu.Hostname()
	if host == "" || strings.EqualFold(host, "localhost") || strings.HasSuffix(strings.ToLower(host), ".localhost") ||
		strings.HasSuffix(strings.ToLower(host), ".local") {
		return nil, false
	}
	if os.Getenv("IRIS_RELAY_LOCAL") != "" {
		return pu, true // the tests' own server, on the loopback address
	}
	ips, err := net.LookupIP(host)
	if err != nil || len(ips) == 0 {
		return nil, false
	}
	for _, ip := range ips {
		if !publicIP(ip) {
			return nil, false
		}
	}
	return pu, true
}

func publicIP(ip net.IP) bool {
	return !(ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() ||
		ip.IsUnspecified() || ip.IsMulticast() || ip.IsInterfaceLocalMulticast() ||
		ip.Equal(net.IPv4bcast) || (ip.To4() != nil && ip.To4()[0] == 100 && ip.To4()[1]&0xc0 == 64)) // 100.64/10, shared address space
}

// cleanHeader keeps a header value on one line.
func cleanHeader(s string) string {
	return strings.Map(func(r rune) rune {
		if r == '\r' || r == '\n' || r < 0x20 {
			return -1
		}
		return r
	}, s)
}

func (r *relay) ServeHTTP(w http.ResponseWriter, q *http.Request) {
	if q.URL.Path != "/v" || subtle.ConstantTimeCompare([]byte(q.URL.Query().Get("k")), []byte(r.key)) != 1 {
		http.NotFound(w, q)
		return
	}
	if q.Method != http.MethodGet || !mediaRequest(q) {
		http.Error(w, "only for videos", http.StatusForbidden)
		return
	}
	pu, ok := publicURL(q.URL.Query().Get("u"))
	if !ok {
		http.Error(w, "bad address", http.StatusBadRequest)
		return
	}
	ref := cleanHeader(q.URL.Query().Get("r"))
	if !strings.HasPrefix(ref, "https://") && !strings.HasPrefix(ref, "http://") {
		ref = ""
	}
	select {
	case r.busy <- struct{}{}:
		defer func() { <-r.busy }()
	case <-q.Context().Done():
		return
	}
	cmds := convertCmds(q.Context(), pu.String(), ref)
	if len(cmds) == 0 {
		http.Error(w, "no converter", http.StatusServiceUnavailable)
		return
	}
	fmt.Fprintln(os.Stderr, "Iris: converting a video for this engine:", pu.Host)
	// each way in turn (the graphics chip, the processor, GStreamer): one that
	// gives nothing (a codec it lacks, a driver that fails) hands over to the next
	for i, cmd := range cmds {
		out, first, ok := startConvert(cmd)
		if !ok {
			if i < len(cmds)-1 {
				fmt.Fprintln(os.Stderr, "Iris: that way gave no video; trying the next")
			}
			continue
		}
		w.Header().Set("Content-Type", "video/webm")
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Cross-Origin-Resource-Policy", "cross-origin") // a video element may show it; scripts may not read it
		stream(w, out, first)
		cmd.Process.Kill() // the page stopped reading, or the video ended
		cmd.Wait()
		return
	}
	http.Error(w, "could not convert", http.StatusBadGateway)
}

// startConvert starts cmd and waits for its first bytes of video (at most
// 25 seconds); ok is false, and cmd is stopped, when none come.
func startConvert(cmd *exec.Cmd) (out io.Reader, first []byte, ok bool) {
	cmd.Stderr = os.Stderr // the converter's own errors, for a terminal
	pipe, err := cmd.StdoutPipe()
	if err != nil || cmd.Start() != nil {
		return nil, nil, false
	}
	got := make(chan []byte, 1)
	go func() {
		buf := make([]byte, 64<<10)
		n, _ := io.ReadAtLeast(pipe, buf, 1)
		got <- buf[:n]
	}()
	select {
	case b := <-got:
		if len(b) > 0 {
			return pipe, b, true
		}
	case <-time.After(25 * time.Second):
	}
	cmd.Process.Kill()
	cmd.Wait()
	return nil, nil, false
}

// stream copies the conversion to the page as it comes.
func stream(w http.ResponseWriter, out io.Reader, first []byte) {
	f, _ := w.(http.Flusher)
	if _, err := w.Write(first); err != nil {
		return
	}
	buf := make([]byte, 64<<10)
	for {
		if f != nil {
			f.Flush()
		}
		n, err := out.Read(buf)
		if n > 0 {
			if _, werr := w.Write(buf[:n]); werr != nil {
				return
			}
		}
		if err != nil {
			return
		}
	}
}

var (
	hwOnce sync.Once
	hwVP9  bool // ffmpeg can encode VP9 on the graphics chip (VA-API)
)

const renderNode = "/dev/dri/renderD128"

// hwEncoder says, once, whether ffmpeg can encode VP9 on this computer's
// graphics chip: a one-frame test, so a missing driver never breaks a video.
func hwEncoder() bool {
	hwOnce.Do(func() {
		p, err := exec.LookPath("ffmpeg")
		if err != nil {
			return
		}
		if _, err := os.Stat(renderNode); err != nil {
			return
		}
		ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
		defer cancel()
		err = exec.CommandContext(ctx, p, "-hide_banner", "-loglevel", "error", "-vaapi_device", renderNode,
			"-f", "lavfi", "-i", "testsrc=size=256x144:rate=30:duration=0.2",
			"-vf", "format=nv12,hwupload", "-c:v", "vp9_vaapi", "-f", "null", "-").Run()
		hwVP9 = err == nil
	})
	return hwVP9
}

// convertCmds are the ways to convert src to WebM on standard output, best
// first: ffmpeg on the graphics chip (VA-API), ffmpeg on the processor, then
// GStreamer, whose decoders include the chip's own (va: H.264, H.265, AV1)
// and Cisco's OpenH264 where ffmpeg has neither. src is a checked public
// http(s) address.
func convertCmds(ctx context.Context, src, ref string) []*exec.Cmd {
	var cmds []*exec.Cmd
	if p, err := exec.LookPath("ffmpeg"); err == nil {
		hdr := "User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36\r\n"
		if ref != "" {
			hdr += "Referer: " + ref + "\r\n"
		}
		// only the network: a playlist cannot point ffmpeg at files on the computer
		in := []string{"-hide_banner", "-loglevel", "error", "-protocol_whitelist", "http,https,tcp,tls,crypto,httpproxy",
			"-headers", hdr}
		audio := []string{"-c:a", "libopus", "-b:a", "128k", "-f", "webm", "pipe:1"}
		if hwEncoder() {
			// decoded and encoded on the graphics chip: sharp, smooth, little processor
			// (a video the chip cannot decode is decoded by the processor and
			// still encoded on the chip)
			args := append(append([]string{}, in...), "-init_hw_device", "vaapi=va:"+renderNode, "-filter_hw_device", "va",
				"-hwaccel", "vaapi", "-hwaccel_device", "va", "-i", src,
				"-map", "0:v:0?", "-map", "0:a:0?",
				"-vf", "format=nv12|vaapi,hwupload,scale_vaapi=w='min(1920,iw)':h=-2:format=nv12",
				"-c:v", "vp9_vaapi", "-b:v", "6M", "-maxrate", "8M")
			cmds = append(cmds, exec.CommandContext(ctx, p, append(args, audio...)...))
		}
		// decoded on the graphics chip when it can (else by the processor),
		// encoded by the processor as fast as it goes, at a quality that stays sharp
		args := append(append([]string{}, in...), "-hwaccel", "auto", "-i", src,
			"-map", "0:v:0?", "-map", "0:a:0?",
			"-vf", "scale='min(1920,iw)':-2",
			"-c:v", "libvpx", "-deadline", "realtime", "-cpu-used", "6", "-threads", "4", "-slices", "4",
			"-crf", "10", "-b:v", "5M", "-qmin", "4", "-qmax", "40", "-lag-in-frames", "0", "-auto-alt-ref", "0")
		cmds = append(cmds, exec.CommandContext(ctx, p, append(args, audio...)...))
	}
	if p, err := exec.LookPath("gst-launch-1.0"); err == nil && !strings.Contains(strings.ToLower(src), ".m3u8") {
		// gst-launch reads its arguments as one pipeline description: the
		// address goes in quotes, and publicURL already refused quotes,
		// spaces and the other characters that could end it
		cmds = append(cmds, exec.CommandContext(ctx, p, "-q", "souphttpsrc", "location=\""+src+"\"", "!", "decodebin", "name=d",
			"webmmux", "name=m", "streamable=true", "!", "fdsink", "fd=1",
			"d.", "!", "queue", "!", "videoconvert", "!", "vp8enc", "deadline=1", "cpu-used=6", "threads=4", "target-bitrate=5000000", "!", "queue", "!", "m.",
			"d.", "!", "queue", "!", "audioconvert", "!", "audioresample", "!", "opusenc", "!", "queue", "!", "m."))
	}
	return cmds
}
