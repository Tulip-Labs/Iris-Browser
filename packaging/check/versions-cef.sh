#!/bin/sh
# The Chromium (CEF) build carries a version of its own (CEF_VERSION in
# linux/src/version_cef.odin), apart from Android
# (versions.sh is Android's); its release notes (packaging/release-notes-cef.md) must
# open with the same one. With a tag (cef-v2.4.0), it must match too.
set -eu
cd "$(dirname "$0")/../.."
cef=$(sed -n 's/^CEF_VERSION :: "\(.*\)"$/\1/p' linux/src/version_cef.odin)
notes=$(sed -n 's/^Iris (Chromium) \([0-9][0-9.]*\):.*/\1/p' packaging/release-notes-cef.md | head -1)
echo "Iris (Chromium) $cef, release notes $notes"
fail=0
[ -n "$cef" ] || { echo "no CEF_VERSION in linux/src/version_cef.odin"; fail=1; }
[ "$notes" = "$cef" ] || { echo "versions differ: $cef and release notes ${notes:-(none)}"; fail=1; }
if [ -n "${1:-}" ]; then
	case "$1" in
	cef-v*) [ "${1#cef-v}" = "$cef" ] || { echo "the tag $1 is not version $cef"; fail=1; } ;;
	*) echo "the tag $1 is not a cef-v tag (cef-v$cef)"; fail=1 ;;
	esac
fi
exit $fail
