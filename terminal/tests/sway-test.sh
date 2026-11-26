#!/bin/sh
# The functional test: Iris Terminal for real, on a headless sway.
#   1. a script prints colours, wide and combining characters, the alternate
#      screen, a link, a title; the screen it leaves must be exactly
#      tests/expected-screen.txt, and the frame it drew must have clear
#      rounded corners, exact colour blocks and text pixels
#   2. keys typed with wtype reach the program (xkb, the keyboard path), and a
#      paste (Ctrl+Shift+V) brings the clipboard
#   3. idle: no CPU is used while nothing changes
#   4. throughput: cat of a 50 MB file (the MB/s is printed; under 50 fails)
# usage: sh tests/sway-test.sh /path/to/iris-terminal
set -eu
bin=$(readlink -f "$1")
here=$(cd "$(dirname "$0")" && pwd)
out=${OUT:-/tmp/terminal-test}
mkdir -p "$out"
export XDG_RUNTIME_DIR=$(mktemp -d) WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 WLR_HEADLESS_OUTPUTS=1
chmod 700 "$XDG_RUNTIME_DIR"
cat > "$out/sway.conf" <<'CONF'
output HEADLESS-1 resolution 1280x800
default_border none
for_window [app_id="io.github.tulip_labs.IrisTerminal"] floating enable
CONF
sway -c "$out/sway.conf" > "$out/sway.log" 2>&1 &
for i in $(seq 1 50); do ls "$XDG_RUNTIME_DIR"/wayland-* >/dev/null 2>&1 && break; sleep 0.2; done
export WAYLAND_DISPLAY=$(basename "$(ls "$XDG_RUNTIME_DIR"/wayland-* | grep -v lock | head -1)")
export LIBGL_ALWAYS_SOFTWARE=1 HOME=$(mktemp -d) IRIS_THEME=dark IRIS_TERMINAL_DEBUG=1
trap 'pkill -x sway 2>/dev/null || true' EXIT
fail() { echo "FAIL: $*"; for f in "$out"/*.log; do echo "--- $f"; tail -30 "$f"; done; exit 1; }

echo "== 1. the screen, the state, the frame"
"$bin" --geometry 60x14 --exec "sh $here/emit.sh" --timeout 20000 \
	--dump-screen "$out/screen.txt" --dump-state "$out/state.txt" --dump-frame "$out/frame.pam" > "$out/run1.log" 2>&1 || fail "iris-terminal exited with $?"
python3 - "$out/screen.txt" "$here/expected-screen.txt" <<'PY'
import sys
got = open(sys.argv[1]).read().rstrip("\n")
want = open(sys.argv[2]).read().rstrip("\n")
if got != want:
    import difflib
    print("\n".join(difflib.unified_diff(want.split("\n"), got.split("\n"), "expected", "got", lineterm="")))
    sys.exit("the screen is not what the script printed")
print("screen: exact (%d lines)" % len(want.split("\n")))
PY
for line in "title: iris title" "alt: false" "history: 0" "link 0,4 https://example.org/x" "link 3,4 https://example.org/x" \
	"cell 0,0 p1/-/- r" "cell 4,0 p2/-/b b" "cell 9,0 #0a141e/-/- t" "cell 14,0 p208/-/- o" "cell 0,1 -/#ff0000/-" \
	"cell 2,1 -/#00ff00/-" "cell 4,1 -/#0000ff/-" "cell 0,8 -/-/u3 c" "cell 6,8 -/-/s s" "cell 13,8 -/-/r r"; do
	grep -qF "$line" "$out/state.txt" || fail "the state lacks: $line"
done
echo "state: colours, truecolor, 256, bold, curly underline, strike, reverse, link, title, main screen after the alt screen"
cat "$out/state.txt" | grep -E "^(size|layout|cursor):"
python3 "$here/check-frame.py" "$out/frame.pam" "$out/state.txt" || fail "the frame"
grep -q "iris-terminal" "$out/run1.log" || true

echo "== 1b. the container name in the title bar"
"$bin" --geometry 40x8 --container demo --exec "printf hi" --timeout 20000 --dump-state "$out/state-container.txt" --dump-frame "$out/frame-container.pam" > "$out/run1b.log" 2>&1 || fail "container run"
python3 - "$out/state-container.txt" "$out/state.txt" <<'PY'
import re, sys
oy = lambda f: int(re.search(r"oy=(\d+)", open(f).read()).group(1))
a, b = oy(sys.argv[1]), oy(sys.argv[2])
print("origin y with the container bar:", a, "without:", b)
assert a > b, "the container bar takes no room"
PY

echo "== 2. keys and paste"
rm -f "$out/typed.txt" "$out/pasted.txt"
"$bin" --geometry 50x10 --exec "head -n 1 > $out/typed.txt" --timeout 30000 > "$out/run2.log" 2>&1 &
pid=$!
sleep 3
wtype -s 400 "hello iris" -k Return || fail "wtype"
for i in $(seq 1 30); do [ -s "$out/typed.txt" ] && break; sleep 0.2; done
wait $pid || true
[ "$(cat "$out/typed.txt")" = "hello iris" ] || fail "typed: '$(cat "$out/typed.txt" 2>/dev/null)'"
echo "typed text reached the program: hello iris"
"$bin" --geometry 50x10 --exec "head -n 1 > $out/pasted.txt" --timeout 30000 --dump-screen "$out/paste-screen.txt" > "$out/run2b.log" 2>&1 &
pid=$!
sleep 3
printf 'pasted from the clipboard' | wl-copy > "$out/wl-copy.log" 2>&1 || echo "wl-copy: exit $?"
sleep 1
echo "clipboard as a client sees it: $(wl-paste -n 2>&1 || true)"
# one wtype: its virtual keyboard is the seat's only keyboard, and it goes when wtype ends
wtype -s 400 -M ctrl -M shift -k v -m shift -m ctrl -s 1500 -k Return || echo "wtype: exit $?"
for i in $(seq 1 30); do [ -s "$out/pasted.txt" ] && break; sleep 0.2; done
wait $pid || true
[ "$(cat "$out/pasted.txt")" = "pasted from the clipboard" ] || { echo "screen:"; cat "$out/paste-screen.txt" 2>/dev/null; fail "pasted: '$(cat "$out/pasted.txt" 2>/dev/null)'"; }
echo "Ctrl+Shift+V pasted the clipboard"

echo "== 3. idle CPU"
"$bin" --geometry 80x24 --exec "sleep 14" --timeout 30000 > "$out/run3.log" 2>&1 &
bgpid=$!
sleep 4
pid=$(pgrep -x iris-terminal | head -1)
[ -n "$pid" ] || fail "no iris-terminal running"
grep -E 'VmRSS|VmHWM' /proc/$pid/status
t0=$(awk '{print $14+$15}' /proc/$pid/stat); sleep 5; t1=$(awk '{print $14+$15}' /proc/$pid/stat)
echo "CPU ticks used in 5 idle seconds: $((t1 - t0))"
[ $((t1 - t0)) -le 1 ] || fail "the idle terminal used CPU"
kill $bgpid 2>/dev/null || true
wait $bgpid 2>/dev/null || true

echo "== 4. throughput"
yes 'The quick brown fox jumps over the lazy dog 0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ' | head -c 52428800 > "$out/big.txt"
"$bin" --geometry 100x30 --exec "cat $out/big.txt" --stats --timeout 60000 > "$out/run4.log" 2>&1 || fail "cat"
grep stats "$out/run4.log" || true
grep -E '^bytes=' "$out/run4.log"
mbs=$(sed -n 's/^bytes=[0-9]* ms=[0-9]* MB\/s=\([0-9.]*\).*/\1/p' "$out/run4.log")
python3 -c "import sys; v=float('$mbs'); print('throughput: %.1f MB/s' % v); sys.exit(0 if v >= 50 else 'under 50 MB/s')"
echo "all functional checks passed"
