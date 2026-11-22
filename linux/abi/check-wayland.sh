#!/bin/sh
# The Odin Wayland tables against wayland-scanner's: both dump every
# interface (name, version, messages, signatures, argument types) and the
# dumps must be the same.  Usage: abi/check-wayland.sh  (from the base dir)
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
if diff -u "$t/c.txt" "$t/o.txt"; then
	echo "Wayland tables: $(grep -c '^[a-z]' "$t/c.txt") interfaces match wayland-scanner"
else
	echo "Wayland tables differ from wayland-scanner's" >&2
	exit 1
fi
