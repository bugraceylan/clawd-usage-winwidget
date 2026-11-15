#!/usr/bin/env bash
# clawd-sessions-publish - publishes this machine's live Claude Code sessions to a
# secret GitHub gist, so clawd-usage-winwidget on another computer (on any network)
# can show them next to its own: name, working / waiting / idle, folder.
#
# Reads Claude Code's own registry (~/.claude/sessions/<pid>.json), keeps the sessions
# whose process is still alive and writes them to the gist in the shape the widget
# reads (see remoteSessions in the README). The gist is written when something
# changes and every CLAWD_HEARTBEAT seconds anyway - the widget drops a feed older
# than two minutes, so a machine that goes off simply disappears from the list.
#
# Settings (environment, or ~/.config/clawd-publish/env):
#   CLAWD_GIST_ID      the gist to write (required)
#   CLAWD_GIST_TOKEN   a GitHub token that may write gists (required)
#   CLAWD_HOST         the name shown in the widget (default: hostname -s)
#   CLAWD_INTERVAL     seconds between looks at the sessions (default 5)
#   CLAWD_HEARTBEAT    seconds between writes when nothing changed (default 45)
#   CLAUDE_CONFIG_DIR  Claude Code's folder, as Claude Code itself reads it (default ~/.claude)
#
# Needs bash, curl and jq.
#   --once   write once and exit (for a test)
#   --dry    print what would be written and exit; needs no gist or token
set -u

CONF="${XDG_CONFIG_HOME:-$HOME/.config}/clawd-publish/env"
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"

GIST_ID="${CLAWD_GIST_ID:-}"
TOKEN="${CLAWD_GIST_TOKEN:-}"
HOST_NAME="${CLAWD_HOST:-$(hostname -s 2>/dev/null || hostname)}"
INTERVAL="${CLAWD_INTERVAL:-5}"
HEARTBEAT="${CLAWD_HEARTBEAT:-45}"
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

feed() {   # $1 - the sessions array
    jq -nc --arg host "$HOST_NAME" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson s "$1" \
        '{ generatedAt: $at, host: $host, sessions: $s }'
}

publish() {   # $1 - the sessions array
    local body
    body=$(jq -nc --arg file "$FILE" --arg content "$(feed "$1")" '{ files: { ($file): { content: $content } } }')
    curl -fsS -X PATCH --max-time 20 \
         -H "Authorization: Bearer $TOKEN" \
         -H "Accept: application/vnd.github+json" \
         -H "X-GitHub-Api-Version: 2022-11-28" \
         -H "User-Agent: clawd-sessions-publish" \
         --data "$body" -o /dev/null \
         "https://api.github.com/gists/$GIST_ID"
}

main() {
    for cmd in curl jq; do
        command -v "$cmd" >/dev/null 2>&1 || { echo "clawd-publish: $cmd is not installed" >&2; exit 1; }
    done
    if [ "${1:-}" = "--dry" ]; then
        s=$(collect) && feed "$s" | jq .
        exit $?
    fi
    [ -n "$GIST_ID" ] || { echo "clawd-publish: CLAWD_GIST_ID is not set ($CONF)" >&2; exit 1; }
    [ -n "$TOKEN" ]   || { echo "clawd-publish: CLAWD_GIST_TOKEN is not set ($CONF)" >&2; exit 1; }

    if [ "${1:-}" = "--once" ]; then
        s=$(collect) && publish "$s" && echo "clawd-publish: wrote $(jq length <<<"$s") session(s) as $HOST_NAME"
        exit $?
    fi

    # Stopped (shutdown, systemctl stop): say "nothing running" rather than leave the
    # last list up for two minutes.
    trap 'publish "[]" >/dev/null 2>&1; exit 0' TERM INT

    local last="" last_at=0 s now
    while :; do
        if s=$(collect); then
            now=$(date +%s)
            if [ "$s" != "$last" ] || [ $((now - last_at)) -ge "$HEARTBEAT" ]; then
                # Failed (no network, GitHub down): not remembered, so the next look tries again.
                if publish "$s"; then last="$s"; last_at=$now; fi
            fi
        fi
        sleep "$INTERVAL" &
        wait $!
    done
}

# Sourced (tools/publish-test.sh) - only the functions.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
