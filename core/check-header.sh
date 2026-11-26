#!/bin/sh
# every exported Rust function is in the header, and the header declares nothing else
set -eu
cd "$(dirname "$0")"
rs=$(grep -rhoE 'pub (unsafe )?extern "C" fn iris_[a-z0-9_]+' src | sed 's/.* //' | sort)
h=$(grep -oE '\biris_[a-z0-9_]+\(' include/iris_core.h | tr -d '(' | sort -u)
[ "$rs" = "$h" ] || { echo "header and exports differ:"; diff -u /dev/fd/3 /dev/fd/4 3<<EOF 4<<EOF2 || true
$rs
EOF
$h
EOF2
exit 1; }
echo "header ok: $(echo "$rs" | wc -l) functions"
