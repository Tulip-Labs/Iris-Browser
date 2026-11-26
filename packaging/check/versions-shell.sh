#!/bin/sh
# Iris Shell has a version of its own (VERSION in shell/src/version.odin),
# apart from the browser's; its release notes (packaging/release-notes-shell.md)
# must open with the same one. With a tag (shell-v1.0.0), it must match too.
set -eu
cd "$(dirname "$0")/../.."
v=$(sed -n 's/^VERSION :: "\(.*\)"$/\1/p' shell/src/version.odin)
notes=$(sed -n 's/^Iris Shell \([0-9][0-9.]*\):.*/\1/p' packaging/release-notes-shell.md | head -1)
echo "Iris Shell $v, release notes $notes"
fail=0
[ -n "$v" ] || { echo "no VERSION in shell/src/version.odin"; fail=1; }
[ "$notes" = "$v" ] || { echo "versions differ: $v and release notes ${notes:-(none)}"; fail=1; }
if [ -n "${1:-}" ]; then
	case "$1" in
	shell-v*) [ "${1#shell-v}" = "$v" ] || { echo "the tag $1 is not version $v"; fail=1; } ;;
	*) echo "the tag $1 is not a shell-v tag (shell-v$v)"; fail=1 ;;
	esac
fi
exit $fail
