#!/usr/bin/env bash
# Installs clawd-sessions-publish for the current user on Linux, as a systemd user
# service that starts with the machine.
#
#   ./install-linux.sh https://<db>.firebaseio.com/feeds/<key> [host-name]
#   ./install-linux.sh <gist-id> [host-name]
#
# A Firebase Realtime Database path needs no token: the database's rules open only
# that path (see the README). For a gist it asks for the GitHub token (not echoed). The
# settings go to ~/.config/clawd-publish/env, readable only by you, and replace what was
# there - run it again to switch the target, the name or the token.
set -eu

TARGET="${1:-}"
HOST_NAME="${2:-$(hostname -s 2>/dev/null || hostname)}"
[ -n "$TARGET" ] || { echo "usage: $0 <firebase-path-url | gist-id> [host-name]" >&2; exit 1; }

here="$(cd "$(dirname "$0")" && pwd)"
for cmd in curl jq systemctl; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "$cmd is not installed (e.g. sudo apt install $cmd)" >&2; exit 1; }
done

conf_dir="${XDG_CONFIG_HOME:-$HOME/.config}/clawd-publish"
mkdir -p "$HOME/.local/bin" "$conf_dir" "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
install -m 755 "$here/clawd-sessions-publish.sh" "$HOME/.local/bin/clawd-sessions-publish.sh"
install -m 644 "$here/clawd-sessions-publish.service" "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/clawd-sessions-publish.service"

umask 077
case "$TARGET" in
    https://*)
        cat > "$conf_dir/env" <<EOF
CLAWD_FIREBASE_URL='$TARGET'
CLAWD_HOST='$HOST_NAME'
EOF
        ;;
    *)
        token="${CLAWD_GIST_TOKEN:-}"
        if [ -z "$token" ]; then
            read -r -s -p "GitHub token that may write gists: " token
            echo
        fi
        [ -n "$token" ] || { echo "no token given" >&2; exit 1; }
        cat > "$conf_dir/env" <<EOF
CLAWD_GIST_ID='$TARGET'
CLAWD_GIST_TOKEN='$token'
CLAWD_HOST='$HOST_NAME'
EOF
        ;;
esac
chmod 600 "$conf_dir/env"

# One write first: a wrong address, rules or token shows up here, not silently in the service.
"$HOME/.local/bin/clawd-sessions-publish.sh" --once

systemctl --user daemon-reload
systemctl --user enable --now clawd-sessions-publish.service
systemctl --user restart clawd-sessions-publish.service

# Without lingering a user service stops when you log out and does not start at boot.
if command -v loginctl >/dev/null 2>&1 && [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" != "yes" ]; then
    echo
    echo "To keep it running when you are logged out and start it at boot, run once:"
    echo "  sudo loginctl enable-linger $USER"
fi
echo
echo "Running. Logs: journalctl --user -u clawd-sessions-publish -f"
