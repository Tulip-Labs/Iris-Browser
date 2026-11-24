#!/bin/sh
# Iris carries its version in three places; they must agree, or Iris for
# Linux tells you about an update you already have (2.2.3 shipped with
# Linux still saying 2.2.2). With a tag (v2.2.4), it must match too.
set -eu
cd "$(dirname "$0")/../.."
linux=$(sed -n 's/^VERSION :: "\(.*\)"$/\1/p' linux/src/shields.odin)
android=$(sed -n 's/^ *versionName = "\(.*\)"$/\1/p' android/app/build.gradle.kts)
code=$(sed -n 's/^ *versionCode = \([0-9]*\)$/\1/p' android/app/build.gradle.kts)
meta=$(sed -n 's/^ *<release version="\([^"]*\)".*/\1/p' packaging/linux/io.github.tulip_labs.Iris.metainfo.xml | head -1)
notes=$(sed -n 's/^Iris \([0-9][0-9.]*\):.*/\1/p' packaging/release-notes.md | head -1)
echo "Linux $linux, Android $android ($code), metainfo $meta, release notes $notes"
fail=0
for v in "$android" "$meta" "$notes"; do
	[ "$v" = "$linux" ] || { echo "versions differ: $linux and $v"; fail=1; }
done
# versionCode grows with the version (2.2.4 is 224); it must never go down
want=$(echo "$linux" | awk -F. '{ printf "%d", $1 * 100 + $2 * 10 + $3 }')
[ "$code" -ge "$want" ] || { echo "versionCode $code is below $want"; fail=1; }
if [ -n "${1:-}" ]; then
	[ "${1#v}" = "$linux" ] || { echo "the tag $1 is not version $linux"; fail=1; }
fi
exit $fail
