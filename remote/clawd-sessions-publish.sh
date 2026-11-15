#!/usr/bin/env bash
# clawd-sessions-publish - publishes this machine's live Claude Code sessions so
# clawd-usage-winwidget on another computer (on any network) can show them next to its
# own: name, working / waiting / idle, folder.
#
# Reads Claude Code's own registry (~/.claude/sessions/<pid>.json), keeps the sessions
# whose process is still alive and writes them, in the shape the widget reads (see
# remoteSessions in the README), to one of:
#
#  - a Firebase Realtime Database path (CLAWD_FIREBASE_URL) - the widget keeps a
#    connection open to it and gets every change pushed at once. No rate limit, so it
#    looks every 2 s and writes each change; a heartbeat every minute.
#  - a secret GitHub gist (CLAWD_GIST_ID + CLAWD_GIST_TOKEN). GitHub allows a user 100
#    gist updates an hour across all their gists, so writes are rationed:
#    CLAWD_WRITES_PER_HOUR, up to CLAWD_BURST back to back, faster changes written
#    together; a heartbeat every 5 minutes.
#
# The feed names its heartbeat and the widget drops a feed older than two of them, so a
# machine that goes off disappears from the list. Turned away (403/429), it waits for
# the reset the server names instead of asking again every few seconds, and says why
# in the log; other failures back off 10 s, 20 s ... 5 min.
#
# Settings (environment, or ~/.config/clawd-publish/env):
#   CLAWD_FIREBASE_URL     the database path to write, e.g.
#                          https://<db>.firebaseio.com/feeds/<key> (wins over the gist)
#   CLAWD_GIST_ID          the gist to write
#   CLAWD_GIST_TOKEN       a GitHub token that may write gists
#   CLAWD_HOST             the name shown in the widget (default: hostname -s)
#   CLAWD_INTERVAL         seconds between looks at the sessions (default 2; gist 5)
#   CLAWD_HEARTBEAT        seconds between writes when nothing changed (default 60; gist 300)
#   CLAWD_WRITES_PER_HOUR  gist: most writes an hour (default 40)
#   CLAWD_BURST            gist: writes allowed back to back (default 4)
#   CLAUDE_CONFIG_DIR      Claude Code's folder, as Claude Code itself reads it (default ~/.claude)
#
# Needs bash, curl and jq.
#   --once   write once and exit (for a test)
#   --dry    print what would be written and exit; needs no target
set -u

CONF="${XDG_CONFIG_HOME:-$HOME/.config}/clawd-publish/env"
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"

FIREBASE_URL="${CLAWD_FIREBASE_URL:-}"
GIST_ID="${CLAWD_GIST_ID:-}"
TOKEN="${CLAWD_GIST_TOKEN:-}"
HOST_NAME="${CLAWD_HOST:-$(hostname -s 2>/dev/null || hostname)}"
if [ -n "$FIREBASE_URL" ]; then
    INTERVAL="${CLAWD_INTERVAL:-2}"
    HEARTBEAT="${CLAWD_HEARTBEAT:-60}"
else
    INTERVAL="${CLAWD_INTERVAL:-5}"
    HEARTBEAT="${CLAWD_HEARTBEAT:-300}"
fi
WRITES_PER_HOUR="${CLAWD_WRITES_PER_HOUR:-40}"
BURST="${CLAWD_BURST:-4}"
BLOCKED_UNTIL=0   # no write before this (epoch seconds): a rate limit or a failure backoff
SESS_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SESS_DIR="${SESS_DIR%/}/sessions"
FILE="sessions.json"

# The process's arguments, one per line.
proc_args() { tr '\0' '\n' < "/proc/$1/cmdline" 2>/dev/null; }

# Is <pid> the Claude Code process that wrote <file>? Session files are not removed
# when a process dies, and after a reboot low pids come round again - a file can name
# a pid that is now some other program, even a shell whose command line mentions
# claude (tmux's `bash -c "claude ..."`). So:
#  - the program itself must be Claude Code: its executable (the native build lives
#    under .../claude/versions/<ver>) or, for an npm install, node running claude's script;
#  - and it must have started before the file was last written: a process that started
#    later cannot have written it.
proc_is_session() {
    local pid=$1 file=$2 exe base start mtime
    [ -d "/proc/$pid" ] || return 1
    exe=$(readlink "/proc/$pid/exe" 2>/dev/null) || return 1
    exe=${exe% (deleted)}            # the binary was replaced by an update while running
    base=${exe##*/}
    case "$base" in
        node|node[0-9]*|bun)
            proc_args "$pid" | sed -n 2p | grep -qi 'claude' || return 1 ;;
        *)
            case "$exe" in *[Cc]laude*) ;; *) return 1 ;; esac ;;
    esac
    start=$(proc_start "$pid") || return 1
    mtime=$(stat -c %Y "$file" 2>/dev/null) || return 1
    [ "$start" -le $((mtime + 2)) ]
}

# When <pid> started, in seconds since the epoch: /proc/<pid>/stat field 22 (clock
# ticks since boot) + the boot time. The fields are counted after the ")" that closes
# the program name - the name itself may contain spaces.
proc_start() {
    local ticks btime hz
    ticks=$(sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f20)
    btime=$(awk '/^btime/ { print $2 }' /proc/stat 2>/dev/null)
    hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
    [ -n "$ticks" ] && [ -n "$btime" ] || return 1
    echo $((btime + ticks / hz))
}

# The name the session has in Remote Control - `--remote-control <name>` or
# `--remote-control=<name>` on its command line. The registry's own name is often an
# automatic one (vako-58) or differs in case, so this one wins when it is there.
proc_rc_name() {
    proc_args "$1" | awk '
        want            { if ($0 !~ /^-/) print; exit }
        /^--remote-control=/ { sub(/^--remote-control=/, ""); print; exit }
        $0 == "--remote-control" { want = 1 }'
}

# The live sessions as one JSON array.
collect() {
    local f pid rc
    for f in "$SESS_DIR"/*.json; do
        [ -e "$f" ] || continue
        pid=$(jq -r '.pid // empty' "$f" 2>/dev/null) || continue
        [ -n "$pid" ] && proc_is_session "$pid" "$f" || continue
        rc=$(proc_rc_name "$pid")
        jq -c --arg rc "$rc" '{ name: (if $rc != "" then $rc else (.name // "") end), cwd: (.cwd // ""),
                 status: (.status // ""), waitingFor: (.waitingFor // ""), kind: (.kind // ""),
                 sessionId: (.sessionId // "") }' "$f" 2>/dev/null
    done | jq -sc 'sort_by(.sessionId)'
}

# heartbeat: how often the feed is written at the least - the widget waits two of them
# before it calls the feed stale.
feed() {   # $1 - the sessions array
    jq -nc --arg host "$HOST_NAME" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson s "$1" \
           --argjson hb "$HEARTBEAT" \
        '{ generatedAt: $at, host: $host, heartbeat: $hb, sessions: $s }'
}

# How long to wait after GitHub turned a write away: <headers file> <http code> <now>.
# Prints seconds for a rate limit - Retry-After, else the reset of an exhausted limit
# (at least a minute) - and nothing for any other refusal.
limit_wait() {
    local h=$1 code=$2 now=$3 ra rem reset w
    case "$code" in 403|429) ;; *) return 0 ;; esac
    ra=$(grep -i '^retry-after:' "$h" 2>/dev/null | tr -dc '0-9')
    rem=$(grep -i '^x-ratelimit-remaining:' "$h" 2>/dev/null | tr -dc '0-9')
    reset=$(grep -i '^x-ratelimit-reset:' "$h" 2>/dev/null | tr -dc '0-9')
    if [ -n "$ra" ]; then w=$ra
    elif [ "$rem" = "0" ] && [ -n "$reset" ]; then w=$((reset - now + 5))
    elif [ "$code" = "429" ]; then w=300
    else return 0
    fi
    [ "$w" -lt 60 ] && w=60
    echo "$w"
}

# Firebase's REST address of a path: the path + .json, a query (auth=...) after it.
firebase_json_url() {   # $1 - the database path's address
    local u=$1 q=""
    case "$u" in *\?*) q="?${u#*\?}"; u=${u%%\?*} ;; esac
    u=${u%/}
    case "$u" in *.json) ;; *) u="$u.json" ;; esac
    echo "$u$q"
}

# Writes the feed. 0 - written. Otherwise says why in the log (the server's message,
# never the token) and, for a rate limit, sets BLOCKED_UNTIL to when it lifts.
publish() {   # $1 - the sessions array
    local body hdr out code msg wait now
    hdr=$(mktemp) out=$(mktemp)
    if [ -n "$FIREBASE_URL" ]; then
        # The whole feed in one PUT: the widget gets it as one change.
        code=$(curl -sS -X PUT --max-time 20 -D "$hdr" -o "$out" -w '%{http_code}' \
                    -H "Content-Type: application/json" \
                    -H "User-Agent: clawd-sessions-publish" \
                    --data "$(feed "$1")" \
                    "$(firebase_json_url "$FIREBASE_URL")") || code=000
    else
        body=$(jq -nc --arg file "$FILE" --arg content "$(feed "$1")" '{ files: { ($file): { content: $content } } }')
        code=$(curl -sS -X PATCH --max-time 20 -D "$hdr" -o "$out" -w '%{http_code}' \
                    -H "Authorization: Bearer $TOKEN" \
                    -H "Accept: application/vnd.github+json" \
                    -H "X-GitHub-Api-Version: 2022-11-28" \
                    -H "User-Agent: clawd-sessions-publish" \
                    --data "$body" \
                    "https://api.github.com/gists/$GIST_ID") || code=000
    fi
    if [ "$code" = "200" ]; then rm -f "$hdr" "$out"; return 0; fi
    now=$(date +%s)
    # GitHub says .message, Firebase .error ("Permission denied" - check the rules).
    msg=$(jq -r '.message // .error // empty' "$out" 2>/dev/null | cut -c1-200)
    wait=$(limit_wait "$hdr" "$code" "$now")
    if [ -n "$wait" ]; then
        BLOCKED_UNTIL=$((now + wait))
        echo "clawd-publish: rate limited (HTTP $code), next write in ${wait}s: $msg" >&2
    else
        echo "clawd-publish: HTTP $code: ${msg:-no answer}" >&2
    fi
    rm -f "$hdr" "$out"
    return 1
}

main() {
    for cmd in curl jq; do
        command -v "$cmd" >/dev/null 2>&1 || { echo "clawd-publish: $cmd is not installed" >&2; exit 1; }
    done
    if [ "${1:-}" = "--dry" ]; then
        s=$(collect) && feed "$s" | jq .
        exit $?
    fi
    if [ -z "$FIREBASE_URL" ]; then
        [ -n "$GIST_ID" ] || { echo "clawd-publish: set CLAWD_FIREBASE_URL or CLAWD_GIST_ID ($CONF)" >&2; exit 1; }
        [ -n "$TOKEN" ]   || { echo "clawd-publish: CLAWD_GIST_TOKEN is not set ($CONF)" >&2; exit 1; }
    fi

    if [ "${1:-}" = "--once" ]; then
        s=$(collect) && publish "$s" && echo "clawd-publish: wrote $(jq length <<<"$s") session(s) as $HOST_NAME"
        exit $?
    fi

    # Stopped (shutdown, systemctl stop): say "nothing running" rather than leave the
    # last list up until it goes stale - unless the server is turning writes away anyway.
    trap '[ "$(date +%s)" -ge "$BLOCKED_UNTIL" ] && publish "[]" >/dev/null 2>&1; exit 0' TERM INT

    # The ration: credit in seconds, a write costs 3600 / WRITES_PER_HOUR of it, and it
    # builds up with time to BURST writes' worth. Firebase has no such limit: free.
    local cost=$((3600 / WRITES_PER_HOUR)) cap credit tick
    [ -n "$FIREBASE_URL" ] && cost=0
    cap=$((cost * BURST)); credit=$cap; tick=$(date +%s)
    local last="" last_at=0 s now fail_wait=0
    while :; do
        now=$(date +%s)
        credit=$((credit + now - tick)); [ "$credit" -gt "$cap" ] && credit=$cap; tick=$now
        if [ "$now" -ge "$BLOCKED_UNTIL" ] && [ "$credit" -ge "$cost" ] && s=$(collect); then
            if [ "$s" != "$last" ] || [ $((now - last_at)) -ge "$HEARTBEAT" ]; then
                credit=$((credit - cost))   # an attempt costs even when it fails
                if publish "$s"; then
                    last="$s"; last_at=$now; fail_wait=0
                elif [ "$BLOCKED_UNTIL" -le "$now" ]; then
                    # Not a rate limit (no network, GitHub down): back off 10 s, 20 s ... 5 min.
                    # Not remembered, so the latest state goes out once it works again.
                    fail_wait=$(( fail_wait ? fail_wait * 2 : 10 )); [ "$fail_wait" -gt 300 ] && fail_wait=300
                    BLOCKED_UNTIL=$((now + fail_wait))
                fi
            fi
        fi
        sleep "$INTERVAL" &
        wait $!
    done
}

# Sourced (tools/publish-test.sh) - only the functions.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
