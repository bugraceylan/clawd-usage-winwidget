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
# Needs bash, curl and jq.  --once: write once and exit (for a test).
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

for cmd in curl jq; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "clawd-publish: $cmd is not installed" >&2; exit 1; }
done
[ -n "$GIST_ID" ] || { echo "clawd-publish: CLAWD_GIST_ID is not set ($CONF)" >&2; exit 1; }
[ -n "$TOKEN" ]   || { echo "clawd-publish: CLAWD_GIST_TOKEN is not set ($CONF)" >&2; exit 1; }

# The live sessions as one JSON array. A file can outlive its process: the pid must
# exist and still be Claude Code (a reused pid belongs to some other program).
collect() {
    local f pid
    for f in "$SESS_DIR"/*.json; do
        [ -e "$f" ] || continue
        pid=$(jq -r '.pid // empty' "$f" 2>/dev/null) || continue
        [ -n "$pid" ] && [ -d "/proc/$pid" ] || continue
        tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qi claude || continue
        jq -c '{ name: (.name // ""), cwd: (.cwd // ""), status: (.status // ""),
                 waitingFor: (.waitingFor // ""), kind: (.kind // ""), sessionId: (.sessionId // "") }' \
            "$f" 2>/dev/null
    done | jq -sc 'sort_by(.sessionId)'
}

publish() {   # $1 - the sessions array
    local body
    body=$(jq -nc --arg file "$FILE" --arg host "$HOST_NAME" \
                  --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson s "$1" \
           '{ files: { ($file): { content: ({ generatedAt: $at, host: $host, sessions: $s } | tojson) } } }')
    curl -fsS -X PATCH --max-time 20 \
         -H "Authorization: Bearer $TOKEN" \
         -H "Accept: application/vnd.github+json" \
         -H "X-GitHub-Api-Version: 2022-11-28" \
         -H "User-Agent: clawd-sessions-publish" \
         --data "$body" -o /dev/null \
         "https://api.github.com/gists/$GIST_ID"
}

if [ "${1:-}" = "--once" ]; then
    s=$(collect) && publish "$s" && echo "clawd-publish: wrote $(jq length <<<"$s") session(s) as $HOST_NAME"
    exit $?
fi

# Stopped (shutdown, systemctl stop): say "nothing running" rather than leave the
# last list up for two minutes.
trap 'publish "[]" >/dev/null 2>&1; exit 0' TERM INT

last=""
last_at=0
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
