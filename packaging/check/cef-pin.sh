#!/bin/sh
# Reads packaging/cef_version.lock. In CI it writes CEF_VERSION, CEF_TARBALL
# (the name, without .tar.bz2), CEF_DIRNAME, CEF_SHA1 and CEF_SHA256 to
# $GITHUB_ENV; by hand, `eval "$(sh packaging/check/cef-pin.sh --print)"`.
#   cef-pin.sh --verify FILE   checks FILE against the lock's checksums
set -eu
lock="$(dirname "$0")/../cef_version.lock"
get() { sed -n "s/^$1=//p" "$lock" | head -n1; }
ver=$(get cef_version); sha1=$(get sha1); sha256=$(get sha256)
case "$ver" in
  [0-9]*.[0-9]*.[0-9]*+g*+chromium-[0-9]*.[0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "cef_version.lock: bad cef_version '$ver'" >&2; exit 1 ;;
esac
name="cef_binary_${ver}_linux64_minimal"
case "${1:-}" in
  --verify)
    f=${2:?file}
    if [ -n "$sha1" ];   then echo "$sha1  $f"   | sha1sum -c -   || { echo "CEF tarball SHA-1 differs from cef_version.lock" >&2; exit 1; }; fi
    if [ -n "$sha256" ]; then echo "$sha256  $f" | sha256sum -c - || { echo "CEF tarball SHA-256 differs from cef_version.lock" >&2; exit 1; }; fi
    [ -n "$sha1$sha256" ] || echo "::warning::cef_version.lock has no checksums yet; the next cef-update run fills them in"
    ;;
  --print)
    printf 'CEF_VERSION=%s\nCEF_TARBALL=%s\nCEF_DIRNAME=%s\nCEF_SHA1=%s\nCEF_SHA256=%s\n' "$ver" "$name" "$name" "$sha1" "$sha256"
    ;;
  *)
    : "${GITHUB_ENV:?run in CI, or use --print}"
    sh "$0" --print >> "$GITHUB_ENV"
    ;;
esac
