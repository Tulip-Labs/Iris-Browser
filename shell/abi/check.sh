#!/bin/sh
# The Wayland tables of wl/protocols_shell.odin (layer shell, the ext capture
# protocols) against wayland-scanner's: both dump every interface (name,
# version, messages, signatures, argument types), and each message the two
# have must be the same, in the same place. The ext-* protocols are compared
# with the copy in the system's wayland-protocols (so a slip in the XML copied
# here shows up); wlr-layer-shell is not part of wayland-protocols, so its
# own XML (protocols/) is used. Run from anywhere: sh abi/check.sh
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
P=$(pkg-config --variable=pkgdatadir wayland-protocols)
# xdg_popup (the layer surface's get_popup) lives in xdg-shell
wayland-scanner private-code "$P/stable/xdg-shell/xdg-shell.xml" "$t/xdg-shell.c"
: > "$t/names.txt"
for x in $(cat "$here/tools/protocols.txt"); do
	src=$(find "$P" -name "$x.xml" 2>/dev/null | head -1)
	if [ -n "$src" ]; then echo "$x: the system's $src"; else src="$here/protocols/$x.xml"; echo "$x: ours (not in wayland-protocols)"; fi
	wayland-scanner private-code "$src" "$t/gen-$x.c"
	# the interfaces of OUR copy: what the Odin tables hold
	sed -n 's/.*<interface name="\([a-z0-9_]*\)".*/\1/p' "$here/protocols/$x.xml" >> "$t/names.txt"
done
python3 - "$t" "$here/abi/wl_dump.c" <<'PY'
import sys
t, dump = sys.argv[1:]
names = open(t + "/names.txt").read().split()
c = ["#include <stdio.h>", "#include <wayland-client.h>"]
c += [f"extern const struct wl_interface {n}_interface;" for n in names]
c.append(open(dump).read())
c.append("int main(void){")
c += [f" dump(&{n}_interface);" for n in names]
c.append(" return 0;\n}")
open(t + "/dump.c", "w").write("\n".join(c) + "\n")
o = ["package wl_dump", 'import "core:fmt"', 'import wl "shellwl:wl"', open(dump.replace(".c", ".odin")).read(), "main :: proc() {", "\tall := [?]^wl.Interface{"]
o += [f"\t\t&wl.{n}_interface," for n in names]
o += ["\t}", "\tfor i in all do dump(i)", "}"]
open(t + "/dump.odin", "w").write("\n".join(o) + "\n")
PY
mkdir "$t/odin"; mv "$t/dump.odin" "$t/odin/"
cc -o "$t/c" "$t/dump.c" "$t"/gen-*.c "$t/xdg-shell.c" $(pkg-config --cflags --libs wayland-client)
"$t/c" > "$t/c.txt"
L=$(pkg-config --libs-only-L wayland-client | tr -s ' ')
# (an empty -extra-linker-flags is an error in Odin: only when there is something)
if [ -n "$L" ]; then
	odin build "$t/odin" -collection:shellwl="$here" -out:"$t/o" -o:none -extra-linker-flags:"$L"
else
	odin build "$t/odin" -collection:shellwl="$here" -out:"$t/o" -o:none
fi
"$t/o" > "$t/o.txt"
python3 - "$t/c.txt" "$t/o.txt" <<'PY'
import sys

def read(path):
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
    print("Newer on this system (the extra messages are past what the shell binds):", ", ".join(newer))
if problems:
    print("Wayland tables differ from wayland-scanner's:", file=sys.stderr)
    for p in problems:
        print("  " + p, file=sys.stderr)
    sys.exit(1)
print(f"Wayland tables: {len(o)} interfaces match wayland-scanner's, message by message")
PY
