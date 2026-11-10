#!/bin/bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$project_dir"
if [[ "$(id -u)" == 0 ]]; then
    echo 'Run as your normal macOS user; the script requests sudo only for the fixed restart permission.' >&2
    exit 1
fi
swift build --configuration release
# Root creates and validates its own temporary file, never a user-writable sudoers file.
sudo /bin/sh -s -- "$(id -u)" <<'ROOT'
set -eu
case "$1" in ''|*[!0-9]*) exit 1 ;; esac
mkdir -p /private/etc/sudoers.d
rule=$(mktemp /private/etc/sudoers.d/.displaylink-guard.XXXXXX)
trap 'rm -f "$rule"' EXIT HUP INT TERM
printf '#%s ALL=(root) NOPASSWD: /bin/launchctl kickstart -k system/com.displaylink.DisplayLinkManager.PrivilegedHelper\n' "$1" > "$rule"
chown root:wheel "$rule"
chmod 0440 "$rule"
/usr/sbin/visudo -cf "$rule"
mv -f "$rule" "/private/etc/sudoers.d/displaylink-guard-$1"
ROOT
exec "$project_dir/.build/release/displaylink-guard" install
