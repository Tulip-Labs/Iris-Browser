#!/bin/sh
# The Odin Wayland tables against wayland-scanner's: both dump every
# interface (name, version, messages, signatures, argument types). Wayland
# only ever adds messages at the end of an interface, in a newer version, so
# the tables agree when every message both have is the same, in the same
# place; either may be newer (Iris binds each interface at a version its own
# table has). Usage: abi/check-wayland.sh  (from the base dir)
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
P=$(pkg-config --variable=pkgdatadir wayland-protocols)
for x in $(cat "$here/tools/protocols.txt"); do
	wayland-scanner private-code "$P/$x.xml" "$t/$(basename $x).c"
done
cc -o "$t/c" "$here/abi/wl_dump.c" "$t"/*.c $(pkg-config --cflags --libs wayland-client)
"$t/c" > "$t/c.txt"
odin build "$here/abi/wl_dump.odin" -file -out:"$t/o" -o:none
"$t/o" > "$t/o.txt"
python3 - "$t/c.txt" "$t/o.txt" <<'PY'
import sys

def read(path):
    # "name vN requests events", then that many request and event lines
    out, lines, i = {}, open(path).read().splitlines(), 0
    while i < len(lines):
        name, ver, nr, ne = lines[i].split()
        nr, ne = int(nr), int(ne)
        msgs = [l.strip() for l in lines[i + 1:i + 1 + nr + ne]]
        out[name] = (int(ver[1:]), msgs[:nr], msgs[nr:])
        i += 1 + nr + ne
    return out

c, o = read(sys.argv[1]), read(sys.argv[2])
problems, newer = [], []
for name in sorted(set(c) | set(o)):
    if name not in c or name not in o:
        problems.append(f"{name}: only in {'the Odin tables' if name in o else 'the system'}")
        continue
    (cv, creq, cev), (ov, oreq, oev) = c[name], o[name]
    for kind, a, b in (("request", creq, oreq), ("event", cev, oev)):
        for k in range(min(len(a), len(b))):
            if a[k] != b[k]:
                problems.append(f"{name} {kind} {k}: system '{a[k]}', Odin '{b[k]}'")
    if cv != ov:
        newer.append(f"{name} v{cv} (Odin v{ov})")
if newer:
    print("Newer on this system (the extra messages are past what Iris binds):", ", ".join(newer))
if problems:
    print("Wayland tables differ from wayland-scanner's:", file=sys.stderr)
    for p in problems:
        print("  " + p, file=sys.stderr)
    sys.exit(1)
print(f"Wayland tables: {len(o)} interfaces match wayland-scanner's, message by message")
PY
