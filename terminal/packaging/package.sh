#!/bin/sh
# dist/iris-terminal-x86_64.tar.gz (the binary, install.sh, the launcher
# entry, the icon, the README and the licences in a folder) and
# dist/SHA256SUMS, from the release build ./iris-terminal
set -eu
cd "$(dirname "$0")/.."
[ -x iris-terminal ] || { echo "build first: ./build.sh release" >&2; exit 1; }
v=$(sed -n 's/^VERSION :: "\(.*\)"$/\1/p' src/version.odin)
[ "$(./iris-terminal --version)" = "iris-terminal $v" ] || { echo "the binary is not version $v" >&2; exit 1; }
d=dist/iris-terminal-x86_64
rm -rf dist && mkdir -p "$d"
cp iris-terminal "$d/"
strip "$d/iris-terminal" 2>/dev/null || true
cp packaging/install.sh packaging/io.github.tulip_labs.IrisTerminal.desktop packaging/io.github.tulip_labs.IrisTerminal.svg README.md "$d/"
cp ../LICENSE "$d/LICENSE"
cp assets/DejaVuSansMono-LICENSE.txt "$d/THIRD_PARTY_NOTICES.txt"
chmod 755 "$d/install.sh" "$d/iris-terminal"
(cd dist && tar --owner=0 --group=0 --sort=name -czf iris-terminal-x86_64.tar.gz iris-terminal-x86_64 && sha256sum iris-terminal-x86_64.tar.gz > SHA256SUMS && cat SHA256SUMS)
ls -l dist
