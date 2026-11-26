#!/bin/sh
# The zsh setup, with a real zsh: the config parses, one block goes into
# .zshrc and comes out again, and an interactive zsh draws the prompt (git
# branch, container, exit status) and says where it is (OSC 7) and where its
# prompts are (OSC 133).
# usage: sh tests/zsh-test.sh /path/to/iris-terminal
set -eu
bin=$(readlink -f "$1")
out=${OUT:-/tmp/terminal-test}
mkdir -p "$out"
export HOME=$(mktemp -d) XDG_CONFIG_HOME= XDG_CACHE_HOME=
unset XDG_CONFIG_HOME XDG_CACHE_HOME
fail() { echo "FAIL: $*"; exit 1; }
printf 'export KEEP_ME=1\n' > "$HOME/.zshrc"
cp "$HOME/.zshrc" "$out/zshrc.orig"

"$bin" --setup-zsh
init="$HOME/.config/iris-terminal/zsh/init.zsh"
zsh -n "$init" || fail "zsh -n: the config does not parse"
grep -q '>>> iris-terminal >>>' "$HOME/.zshrc" || fail "no block in .zshrc"
cmp "$HOME/.zshrc.before-iris-terminal" "$out/zshrc.orig" || fail "the backup is not the old .zshrc"
"$bin" --setup-zsh > /dev/null
[ "$(grep -c '>>> iris-terminal >>>' "$HOME/.zshrc")" = 1 ] || fail "the block was added twice"
echo "setup: parses, one block, backup kept"

# a repository and a folder with a space and a non-ASCII name
mkdir -p "$HOME/proj one/é"
git init -q -b main "$HOME/proj one" 2>/dev/null || { mkdir -p "$HOME/proj one/.git"; echo 'ref: refs/heads/main' > "$HOME/proj one/.git/HEAD"; }
# zsh reads the keyboard (the pty), not stdin: the commands are typed
input=$(printf 'cd "%s"\recho SENTINEL_$((1+2))\rfalse\rexit 0\r' "$HOME/proj one/é")
# (a plain zsh first: is the harness itself fine?)
"$bin" --no-window --geometry 100x24 --timeout 20000 --exec "zsh -f -i" --input "$input" --input-after 1000 \
	--dump-screen "$out/zsh-plain.txt" --dump-raw "$out/zsh-plain.raw" || { echo "--- plain zsh -f -i:"; cat -v "$out/zsh-plain.raw"; fail "even zsh -f -i did not finish"; }
grep -q 'SENTINEL_3' "$out/zsh-plain.txt" || { cat "$out/zsh-plain.txt"; fail "a plain zsh did not run the typed command"; }
"$bin" --no-window --geometry 100x24 --timeout 20000 \
	--exec "CONTAINER_ID=testbox zsh -i" --input "$input" --input-after 2500 --dump-raw "$out/zsh.raw" \
	--dump-screen "$out/zsh-screen.txt" --dump-state "$out/zsh-state.txt" || { echo "--- raw:"; cat -v "$out/zsh.raw"; echo "--- screen:"; cat "$out/zsh-screen.txt" || true; fail "zsh did not run"; }
cat "$out/zsh-screen.txt"
grep -q 'SENTINEL_3' "$out/zsh-screen.txt" || fail "the command did not run"
grep -q '⬢ testbox' "$out/zsh-screen.txt" || fail "the prompt lacks the container name"
grep -q 'proj one/é' "$out/zsh-screen.txt" || fail "the prompt lacks the folder"
grep -q 'main' "$out/zsh-screen.txt" || fail "the prompt lacks the git branch"
grep -q '^status: 1' "$out/zsh-state.txt" || fail "OSC 133;D did not carry the exit status of 'false'"
grep -q '^marks: true' "$out/zsh-state.txt" || fail "no OSC 133 prompt marks"
grep -q "^cwd: $HOME/proj one/é" "$out/zsh-state.txt" || { grep '^cwd' "$out/zsh-state.txt"; fail "OSC 7 did not give the folder"; }
echo "prompt: container, folder, branch; the exit status in OSC 133; OSC 7 and OSC 133 seen"

# the opt-out and the removal
"$bin" --remove-zsh
cmp "$HOME/.zshrc" "$out/zshrc.orig" || fail ".zshrc is not as it was after --remove-zsh"
[ ! -e "$init" ] || fail "init.zsh is still there"
echo "remove: .zshrc as it was"
