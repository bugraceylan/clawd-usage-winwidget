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

# GitHub's answers to a write: how long to wait before the next one.
now=1794760000
printf 'HTTP/2 403\r\nx-ratelimit-limit: 100\r\nx-ratelimit-remaining: 0\r\nx-ratelimit-reset: %s\r\nx-ratelimit-resource: gist_update\r\n' $((now + 1200)) > "$tmp/h-gist"
printf 'HTTP/2 403\r\nretry-after: 30\r\n' > "$tmp/h-retry"
printf 'HTTP/2 403\r\nx-ratelimit-remaining: 0\r\nx-ratelimit-reset: %s\r\n' $((now + 10)) > "$tmp/h-soon"
printf 'HTTP/2 429\r\n' > "$tmp/h-429"
printf 'HTTP/2 403\r\nx-ratelimit-remaining: 57\r\n' > "$tmp/h-perm"
check 'exhausted gist_update limit waits for its reset'     [ "$(limit_wait "$tmp/h-gist" 403 $now)" = 1205 ]
check 'retry-after is kept, at least a minute'              [ "$(limit_wait "$tmp/h-retry" 403 $now)" = 60 ]
check 'a reset seconds away still waits a minute'           [ "$(limit_wait "$tmp/h-soon" 403 $now)" = 60 ]
check '429 without hints waits five minutes'                [ "$(limit_wait "$tmp/h-429" 429 $now)" = 300 ]
check '403 with requests left is not a rate limit'          [ -z "$(limit_wait "$tmp/h-perm" 403 $now)" ]
check 'a server error is not a rate limit'                  [ -z "$(limit_wait "$tmp/h-gist" 502 $now)" ]

# Firebase REST addresses.
check 'firebase: path gets .json'          [ "$(firebase_json_url 'https://x.firebaseio.com/feeds/k')" = 'https://x.firebaseio.com/feeds/k.json' ]
check 'firebase: trailing slash'           [ "$(firebase_json_url 'https://x.firebaseio.com/feeds/k/')" = 'https://x.firebaseio.com/feeds/k.json' ]
check 'firebase: .json kept once'          [ "$(firebase_json_url 'https://x.firebaseio.com/feeds/k.json')" = 'https://x.firebaseio.com/feeds/k.json' ]
check 'firebase: query after .json'        [ "$(firebase_json_url 'https://x.firebaseio.com/feeds/k?auth=s')" = 'https://x.firebaseio.com/feeds/k.json?auth=s' ]

if [ "$fails" -eq 0 ]; then echo "all passed ($checks checks)"; else echo "$fails of $checks failed"; exit 1; fi
