#!/usr/bin/env bash
# Checks for remote/clawd-sessions-publish.sh: which processes count as a live session
# and which name a session gets. Starts a few harmless stand-in processes for a few
# seconds; needs /proc (Linux, or Git Bash on Windows). No jq, gist or token.
#
#   bash tools/publish-test.sh        exit code 0 - all passed
set -u
repo="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../remote/clawd-sessions-publish.sh
. "$repo/remote/clawd-sessions-publish.sh"

tmp=$(mktemp -d)
pids=()
cleanup() { kill "${pids[@]}" 2>/dev/null; rm -rf "$tmp"; }
trap cleanup EXIT
fails=0; checks=0
check() {   # <name> <command...>
    local name=$1; shift
    checks=$((checks + 1))
    if "$@"; then :; else echo "FAIL: $name"; fails=$((fails + 1)); fi
}
not() { ! "$@"; }

# A stand-in for the native Claude Code binary: a copy of bash under .../claude/versions/<ver>,
# with the arguments Claude Code is started with. `; :` keeps bash from replacing itself with sleep.
mkdir -p "$tmp/share/claude/versions"
fake="$tmp/share/claude/versions/9.9.9"
cp "$(command -v bash)" "$fake"
"$fake" -c 'sleep 30; :' claude --remote-control HQ2_Lima --model opus &
real=$!; pids+=("$real")
"$fake" -c 'sleep 30; :' claude --remote-control=HQ2_JellyPlay &
eq=$!; pids+=("$eq")
"$fake" -c 'sleep 30; :' claude --remote-control --verbose &
noval=$!; pids+=("$noval")
# tmux's shell: a plain bash whose command line mentions claude.
bash -c 'sleep 30; :' "claude --remote-control HQ2_Demos" &
shell=$!; pids+=("$shell")
sleep 1

# A session file written after its process started, as Claude Code does.
touch "$tmp/fresh.json"
# A leftover from before a reboot: written long before the process now on that pid started.
touch -d '2 hours ago' "$tmp/old.json"

check 'native Claude Code with a fresh file is a session'   proc_is_session "$real" "$tmp/fresh.json"
check 'a file older than the process is a leftover'         not proc_is_session "$real" "$tmp/old.json"
check 'a shell whose command line mentions claude is not'   not proc_is_session "$shell" "$tmp/fresh.json"
check 'a pid that is gone is not'                           not proc_is_session 999999 "$tmp/fresh.json"
check 'a missing file is not'                               not proc_is_session "$real" "$tmp/none.json"
check '--remote-control <name>'                             [ "$(proc_rc_name "$real")" = 'HQ2_Lima' ]
check '--remote-control=<name> keeps its case'              [ "$(proc_rc_name "$eq")" = 'HQ2_JellyPlay' ]
check '--remote-control followed by a flag gives no name'   [ -z "$(proc_rc_name "$noval")" ]
check 'no --remote-control gives no name'                   [ -z "$(proc_rc_name "$$")" ]

if [ "$fails" -eq 0 ]; then echo "all passed ($checks checks)"; else echo "$fails of $checks failed"; exit 1; fi
