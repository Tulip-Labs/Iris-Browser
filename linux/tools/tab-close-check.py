#!/usr/bin/env python3
# A closed tab gives its web process and its memory back (WPE WebKit; run by
# linux.yml under a headless Wayland compositor). Three tabs on three local
# sites, each page holding 150 MB; then two close (IRIS_TEST_CLOSE_TABS, the
# hook in wpe_engine.odin, closes every tab but the first). Passes when
# Iris's process tree then has fewer web processes (WPEWebProcess) and at most
# 75% of the memory it had (WebKit would otherwise keep the closed pages'
# processes five minutes in its process cache).
#   python3 linux/tools/tab-close-check.py linux/iris OUT_DIR
import http.server, os, subprocess, sys, threading, time

iris, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
pages = os.path.join(out, "pages")
os.makedirs(pages, exist_ok=True)
PAGE = """<!doctype html><title>loading</title><body><h1>%s</h1><script>
window.keep = new Uint8Array(150 * 1024 * 1024);
for (let i = 0; i < keep.length; i += 4096) keep[i] = 1;
document.title = 'ready %s';
</script>"""
for name in "abc":
    with open(os.path.join(pages, name + ".html"), "w") as f:
        f.write(PAGE % (name, name))
# tiny rules, compiled in a moment: WebKit compiling the real lists would
# grow Iris's own process in the middle of the measure
rules = os.path.join(out, "rules.json")
with open(rules, "w") as f:
    f.write('[{"trigger":{"url-filter":"never-matches-anything-iris"},"action":{"type":"block"}}]')

class Quiet(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=pages, **k)
    def log_message(self, *a):
        pass

server = http.server.ThreadingHTTPServer(("0.0.0.0", 0), Quiet)
port = server.server_address[1]
threading.Thread(target=server.serve_forever, daemon=True).start()
# three sites (127.0.0.0/8 is all this machine): three web processes
urls = ["http://127.0.0.%d:%d/%s.html" % (i + 1, port, n) for i, n in enumerate("abc")]

def tree(root):
    """pid -> (name, rss in KB) for root and everything under it"""
    kids, info = {}, {}
    for p in os.listdir("/proc"):
        if not p.isdigit():
            continue
        try:
            with open("/proc/%s/stat" % p) as f:
                st = f.read()
            name = st[st.index("(") + 1:st.rindex(")")]
            state, ppid = st[st.rindex(")") + 2:].split()[:2]
            ppid = int(ppid)
            if state in "ZX":
                continue  # ended (not yet reaped): not a process any more
            rss = 0
            with open("/proc/%s/status" % p) as f:
                for line in f:
                    if line.startswith("VmRSS:"):
                        rss = int(line.split()[1])
            kids.setdefault(ppid, []).append(int(p))
            info[int(p)] = (name, rss)
        except (OSError, ValueError, IndexError):
            pass
    out, todo = {}, [root]
    while todo:
        p = todo.pop()
        if p in info:
            out[p] = info[p]
        todo += kids.get(p, [])
    return out

def web(t):
    return {p: v for p, v in t.items() if v[0].startswith(("WPEWebProcess", "WebKitWebProc"))}  # WPE names its own WPEWebProcess

def show(t, label):
    print("%s: %d processes, %d MB" % (label, len(t), sum(v[1] for v in t.values()) // 1024))
    for p, (n, r) in sorted(t.items()):
        print("  %7d %-18s %6d MB" % (p, n, r // 1024))

def attempt(n):
    flag = os.path.join(out, "close-tabs")
    if os.path.exists(flag):
        os.remove(flag)
    env = dict(os.environ, IRIS_TEST_CLOSE_TABS=flag, IRIS_SHIELDS_JSON=rules, HOME=os.path.join(out, "home%d" % n))
    os.makedirs(env["HOME"], exist_ok=True)
    log = open(os.path.join(out, "iris-tabs-%d.log" % n), "w")
    proc = subprocess.Popen([iris] + urls, env=env, stdout=log, stderr=subprocess.STDOUT)
    try:
        # the three pages loaded, each holding its memory
        deadline = time.time() + 120
        while True:
            if proc.poll() is not None:
                return "Iris exited (%s)" % proc.returncode
            w = web(tree(proc.pid))
            if len([1 for v in w.values() if v[1] > 120 * 1024]) >= 3:
                break
            if time.time() > deadline:
                show(tree(proc.pid), "the pages did not load")
                return "the three pages did not load in 120 s"
            time.sleep(1)
        time.sleep(3)
        before = tree(proc.pid)
        show(before, "three tabs")
        with open(flag, "w"):
            pass
        deadline = time.time() + 30
        while os.path.exists(flag):
            if time.time() > deadline or proc.poll() is not None:
                return "the tabs were not closed (the test hook did not run)"
            time.sleep(0.25)
        # their processes end, and the memory comes back
        rss0, n0 = sum(v[1] for v in before.values()), len(web(before))
        deadline = time.time() + 60
        while True:
            after = tree(proc.pid)
            rss1, n1 = sum(v[1] for v in after.values()), len(web(after))
            if n1 < n0 and rss1 <= rss0 * 0.75:
                show(after, "one tab")
                print("PASS: %d -> %d web processes, %d -> %d MB (%.0f%%)" % (n0, n1, rss0 // 1024, rss1 // 1024, 100 * rss1 / rss0))
                return None
            if time.time() > deadline:
                show(after, "one tab, 60 s after closing two")
                return "FAIL: %d -> %d web processes, %d -> %d MB (%.0f%%, needs <= 75%%)" % (n0, n1, rss0 // 1024, rss1 // 1024, 100 * rss1 / rss0)
            time.sleep(1)
    finally:
        try:
            subprocess.run(["grim", os.path.join(out, "screen-%d.png" % n)], timeout=20, capture_output=True)
        except (OSError, subprocess.SubprocessError):
            pass
        proc.terminate()
        try:
            proc.wait(10)
        except subprocess.TimeoutExpired:
            proc.kill()
        log.close()

# a run that could not even start the pages is tried once more; a run that
# measured and failed is the answer
for n in range(2):
    why = attempt(n)
    if why is None:
        sys.exit(0)
    print(why)
    if why.startswith("FAIL"):
        break
    time.sleep(3)
sys.exit(1)
