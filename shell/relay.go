package shell

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"net"
	"net/http"
	"net/url"
	"os/exec"
	"strings"
	"sync"
)

// The video relay. Lite Go's Chromium on Linux has no H.264 or AAC (the
// free builds leave them out), and some sites (LinkedIn, X, many news sites)
// send only that. When such a video cannot play, the page script
// (core.H264Script) points it here instead, and the relay plays it through
// the system's own decoder: ffmpeg (or GStreamer) reads the original and
// turns it into WebM (VP8 and Opus), which Chromium plays. It listens on the
// loopback address only and answers only addresses carrying its key.

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
	go http.Serve(ln, r)
	return r
}

func (r *relay) ServeHTTP(w http.ResponseWriter, q *http.Request) {
	if q.URL.Path != "/v" || q.URL.Query().Get("k") != r.key {
		http.NotFound(w, q)
		return
	}
	src := q.URL.Query().Get("u")
	pu, err := url.Parse(src)
	if err != nil || (pu.Scheme != "https" && pu.Scheme != "http") || pu.Host == "" {
		http.Error(w, "bad address", http.StatusBadRequest)
		return
	}
	ref := q.URL.Query().Get("r")
	select {
	case r.busy <- struct{}{}:
		defer func() { <-r.busy }()
	case <-q.Context().Done():
		return
	}
	cmd := convertCmd(q.Context(), src, ref)
	if cmd == nil {
		http.Error(w, "no converter", http.StatusServiceUnavailable)
		return
	}
	out, err := cmd.StdoutPipe()
	if err != nil || cmd.Start() != nil {
		http.Error(w, "could not convert", http.StatusBadGateway)
		return
	}
	w.Header().Set("Content-Type", "video/webm")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Access-Control-Allow-Origin", "*")
	buf := make([]byte, 64<<10)
	for {
		n, err := out.Read(buf)
		if n > 0 {
			if _, werr := w.Write(buf[:n]); werr != nil {
				break
			}
			if f, ok := w.(http.Flusher); ok {
				f.Flush()
			}
		}
		if err != nil {
			break
		}
	}
	cmd.Process.Kill() // the page stopped reading, or the video ended
	cmd.Wait()
}

// convertCmd is the conversion of src to WebM on standard output: ffmpeg
// when it is installed, else GStreamer.
func convertCmd(ctx context.Context, src, ref string) *exec.Cmd {
	if p, err := exec.LookPath("ffmpeg"); err == nil {
		hdr := "User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36\r\n"
		if strings.HasPrefix(ref, "http") {
			hdr += "Referer: " + ref + "\r\n"
		}
		return exec.CommandContext(ctx, p, "-hide_banner", "-loglevel", "error", "-headers", hdr, "-i", src,
			"-map", "0:v:0?", "-map", "0:a:0?",
			"-c:v", "libvpx", "-deadline", "realtime", "-cpu-used", "8", "-b:v", "2M", "-vf", "scale='min(1280,iw)':-2",
			"-c:a", "libopus", "-b:a", "96k", "-f", "webm", "pipe:1")
	}
	if p, err := exec.LookPath("gst-launch-1.0"); err == nil {
		return exec.CommandContext(ctx, p, "-q", "souphttpsrc", "location="+src, "!", "decodebin", "name=d",
			"webmmux", "name=m", "streamable=true", "!", "fdsink", "fd=1",
			"d.", "!", "queue", "!", "videoconvert", "!", "vp8enc", "deadline=1", "cpu-used=8", "target-bitrate=2000000", "!", "queue", "!", "m.",
			"d.", "!", "queue", "!", "audioconvert", "!", "audioresample", "!", "opusenc", "!", "queue", "!", "m.")
	}
	return nil
}
