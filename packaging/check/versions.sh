#!/bin/sh
# Iris for Android carries its version in two places; they must agree, or the
# app tells you about an update you already have. With a tag (v2.3.1), it must
# match too. (Iris (Chromium) for Linux has its own: versions-cef.sh.)
set -eu
cd "$(dirname "$0")/../.."
android=$(sed -n 's/^ *versionName = "\(.*\)"$/\1/p' android/app/build.gradle.kts)
code=$(sed -n 's/^ *versionCode = \([0-9]*\)$/\1/p' android/app/build.gradle.kts)
notes=$(sed -n 's/^Iris \([0-9][0-9.]*\):.*/\1/p' packaging/release-notes-android.md | head -1)
echo "Android $android ($code), release notes $notes"
fail=0
[ "$notes" = "$android" ] || { echo "versions differ: $android and release notes ${notes:-(none)}"; fail=1; }
# versionCode grows with the version (2.2.4 is 224); it must never go down
want=$(echo "$android" | awk -F. '{ printf "%d", $1 * 100 + $2 * 10 + $3 }')
[ "$code" -ge "$want" ] || { echo "versionCode $code is below $want"; fail=1; }
if [ -n "${1:-}" ]; then
	[ "${1#v}" = "$android" ] || { echo "the tag $1 is not version $android"; fail=1; }
fi
exit $fail
