#!/bin/sh
# dist/iris-shell-x86_64.tar.gz (the binary, install.sh, the README and the
# licence in a folder) and dist/SHA256SUMS, from the release build ./iris-shell
set -eu
cd "$(dirname "$0")/.."
[ -x iris-shell ] || { echo "build first: ./build.sh release" >&2; exit 1; }
v=$(sed -n 's/^VERSION :: "\(.*\)"$/\1/p' src/version.odin)
[ "$(./iris-shell --version)" = "iris-shell $v" ] || { echo "the binary is not version $v" >&2; exit 1; }
rm -rf dist && mkdir -p dist/iris-shell-x86_64
cp iris-shell dist/iris-shell-x86_64/
strip dist/iris-shell-x86_64/iris-shell 2>/dev/null || true
cp packaging/install.sh README.md dist/iris-shell-x86_64/
cp ../LICENSE dist/iris-shell-x86_64/LICENSE
chmod 755 dist/iris-shell-x86_64/install.sh dist/iris-shell-x86_64/iris-shell
(cd dist && tar --owner=0 --group=0 --sort=name -czf iris-shell-x86_64.tar.gz iris-shell-x86_64 && sha256sum iris-shell-x86_64.tar.gz > SHA256SUMS && cat SHA256SUMS)
ls -l dist
