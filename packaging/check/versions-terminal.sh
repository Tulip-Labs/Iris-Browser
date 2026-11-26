#!/bin/sh
# Iris Terminal has a version of its own (VERSION in terminal/src/version.odin),
# apart from the browser's; its release notes (packaging/release-notes-terminal.md)
# must open with the same one, and so must the version the emulator reports
# (XTVERSION, TERM_PROGRAM_VERSION). With a tag (terminal-v1.0.0), it must match too.
set -eu
cd "$(dirname "$0")/../.."
v=$(sed -n 's/^VERSION :: "\(.*\)"$/\1/p' terminal/src/version.odin)
notes=$(sed -n 's/^Iris Terminal \([0-9][0-9.]*\):.*/\1/p' packaging/release-notes-terminal.md | head -1)
echo "Iris Terminal $v, release notes $notes"
fail=0
[ -n "$v" ] || { echo "no VERSION in terminal/src/version.odin"; fail=1; }
[ "$notes" = "$v" ] || { echo "versions differ: $v and release notes ${notes:-(none)}"; fail=1; }
grep -q "t.version = \"$v\"" terminal/term/term.odin || { echo "terminal/term/term.odin reports another version than $v"; fail=1; }
grep -q "TERM_PROGRAM_VERSION=$v\"" terminal/term/pty.odin || { echo "terminal/term/pty.odin sets another TERM_PROGRAM_VERSION than $v"; fail=1; }
grep -q "IRIS_TERMINAL=$v\"" terminal/term/pty.odin || { echo "terminal/term/pty.odin sets another IRIS_TERMINAL than $v"; fail=1; }
if [ -n "${1:-}" ]; then
	case "$1" in
	terminal-v*) [ "${1#terminal-v}" = "$v" ] || { echo "the tag $1 is not version $v"; fail=1; } ;;
	*) echo "the tag $1 is not a terminal-v tag (terminal-v$v)"; fail=1 ;;
	esac
fi
exit $fail
