#!/usr/bin/env bash
# Installs clawd-sessions-publish for the current user on Linux, as a systemd user
# service that starts with the machine.
#
#   ./install-linux.sh <gist-id> [host-name]
#
# Asks for the GitHub token (it is not echoed) and keeps it in
# ~/.config/clawd-publish/env, readable only by you. Run it again to change the
# gist, the name or the token.
set -eu

GIST_ID="${1:-}"
HOST_NAME="${2:-$(hostname -s 2>/dev/null || hostname)}"
[ -n "$GIST_ID" ] || { echo "usage: $0 <gist-id> [host-name]" >&2; exit 1; }

here="$(cd "$(dirname "$0")" && pwd)"
for cmd in curl jq systemctl; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "$cmd is not installed (e.g. sudo apt install $cmd)" >&2; exit 1; }
done

conf_dir="${XDG_CONFIG_HOME:-$HOME/.config}/clawd-publish"
mkdir -p "$HOME/.local/bin" "$conf_dir" "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
install -m 755 "$here/clawd-sessions-publish.sh" "$HOME/.local/bin/clawd-sessions-publish.sh"
install -m 644 "$here/clawd-sessions-publish.service" "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/clawd-sessions-publish.service"

token="${CLAWD_GIST_TOKEN:-}"
if [ -z "$token" ]; then
    read -r -s -p "GitHub token that may write gists: " token
    echo
fi
[ -n "$token" ] || { echo "no token given" >&2; exit 1; }

umask 077
cat > "$conf_dir/env" <<EOF
CLAWD_GIST_ID='$GIST_ID'
CLAWD_GIST_TOKEN='$token'
CLAWD_HOST='$HOST_NAME'
EOF
chmod 600 "$conf_dir/env"

# One write first: a wrong token or gist id shows up here, not silently in the service.
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
