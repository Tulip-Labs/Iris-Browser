#!/usr/bin/env python3
"""Speedometer in Google Chrome, headless, for the benchmark in linux.yml.

    python3 -I packaging/check/speedometer-chrome.py URL [CHROME]

Starts CHROME (default google-chrome) with --headless=new and
--remote-debugging-port, opens URL (a Speedometer 3 page with
?startAutomatically=true) through the DevTools protocol, waits for
benchmarkClient to have results and prints `SPEEDOMETER <score>`, the same
line Iris prints under IRIS_CEF_BENCH_URL. No Playwright, no packages: the
WebSocket the protocol needs is the few lines below.
"""

import base64
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
import urllib.request

TIMEOUT_S = int(os.environ.get("BENCH_TIMEOUT_S", "2400"))


class WebSocket:
    """A client WebSocket, text frames only (what DevTools speaks)."""

    def __init__(self, url):
        assert url.startswith("ws://")
        hostport, _, path = url[5:].partition("/")
        host, _, port = hostport.partition(":")
        self.sock = socket.create_connection((host, int(port or 80)), timeout=60)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall(
            (
                f"GET /{path} HTTP/1.1\r\nHost: {hostport}\r\nUpgrade: websocket\r\n"
                f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
            ).encode()
        )
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise RuntimeError("DevTools closed the connection during the handshake")
            head += chunk
        head, _, self.buf = head.partition(b"\r\n\r\n")
        if b" 101 " not in head.split(b"\r\n")[0]:
            raise RuntimeError("DevTools refused the WebSocket: " + head.decode(errors="replace"))

    def send(self, text):
        data = text.encode()
        n = len(data)
        if n < 126:
            hdr = struct.pack("!BB", 0x81, 0x80 | n)
        elif n < 1 << 16:
            hdr = struct.pack("!BBH", 0x81, 0x80 | 126, n)
        else:
            hdr = struct.pack("!BBQ", 0x81, 0x80 | 127, n)
        mask = os.urandom(4)
        self.sock.sendall(hdr + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

    def _read(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise RuntimeError("DevTools closed the connection")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def recv(self):
        message = b""
        while True:
            b0, b1 = self._read(2)
            n = b1 & 0x7F
            if n == 126:
                (n,) = struct.unpack("!H", self._read(2))
            elif n == 127:
                (n,) = struct.unpack("!Q", self._read(8))
            payload = self._read(n)
            op = b0 & 0x0F
            if op == 0x8:
                raise RuntimeError("DevTools closed the WebSocket")
            if op in (0x9, 0xA):  # ping, pong: no answer needed for this
                continue
            message += payload
            if b0 & 0x80:
                return message.decode()


class DevTools:
    def __init__(self, ws_url):
        self.ws = WebSocket(ws_url)
        self.next_id = 0

    def call(self, method, **params):
        self.next_id += 1
        self.ws.send(json.dumps({"id": self.next_id, "method": method, "params": params}))
        while True:
            m = json.loads(self.ws.recv())
            if m.get("id") == self.next_id:
                if "error" in m:
                    raise RuntimeError(f"{method}: {m['error']}")
                return m.get("result", {})

    def eval(self, expr):
        r = self.call("Runtime.evaluate", expression=expr, returnByValue=True)
        return r.get("result", {}).get("value")


# the score once Speedometer has one: the mean of the iterations, as the
# results page shows it (null while it runs, "invalid" if it failed)
SCORE_JS = """(() => {
  const c = globalThis.benchmarkClient;
  if (!c || !c._hasResults) return null;
  const s = c.metrics && c.metrics.Score;
  if (s && typeof s.mean === "number" && isFinite(s.mean) && s.mean > 0) return s.mean;
  const t = document.getElementById("result-number");
  const v = t ? parseFloat(t.textContent) : NaN;
  return isFinite(v) && v > 0 ? v : "invalid";
})()"""


def main():
    if len(sys.argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    url = sys.argv[1]
    chrome = sys.argv[2] if len(sys.argv) > 2 else "google-chrome"
    if not shutil.which(chrome):
        print(f"{chrome} is not installed", file=sys.stderr)
        return 1
    profile = tempfile.mkdtemp(prefix="speedometer-chrome-")
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    proc = subprocess.Popen(
        [
            chrome,
            "--headless=new",
            f"--remote-debugging-port={port}",
            f"--user-data-dir={profile}",
            "--window-size=1600,1000",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-extensions",
            "--disable-background-networking",
            "--disable-renderer-backgrounding",
            "--disable-background-timer-throttling",
            "about:blank",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        targets = None
        for _ in range(150):
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list", timeout=2) as r:
                    targets = [t for t in json.load(r) if t.get("type") == "page"]
                if targets:
                    break
            except OSError:
                pass
            time.sleep(0.2)
        if not targets:
            print("Chrome's DevTools did not answer", file=sys.stderr)
            return 1
        dt = DevTools(targets[0]["webSocketDebuggerUrl"])
        print("Chrome", dt.call("Browser.getVersion").get("product", "?"), file=sys.stderr)
        dt.call("Page.navigate", url=url)
        start = time.time()
        while time.time() - start < TIMEOUT_S:
            time.sleep(5)
            score = dt.eval(SCORE_JS)
            if score == "invalid":
                print("Speedometer finished without a valid score", file=sys.stderr)
                return 1
            if isinstance(score, (int, float)):
                print(f"SPEEDOMETER {score:.2f}", flush=True)
                return 0
        print(f"no score after {TIMEOUT_S} s", file=sys.stderr)
        return 1
    finally:
        proc.terminate()
        try:
            proc.wait(10)
        except subprocess.TimeoutExpired:
            proc.kill()
        shutil.rmtree(profile, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
