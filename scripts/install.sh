#!/bin/bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$project_dir"
if [[ "$(uname -s)" != Darwin || "$(id -u)" == 0 ]]; then
    echo 'Run from your normal active macOS login; do not run the installer with sudo.' >&2
    exit 1
fi
if ! command -v swift >/dev/null || ! swift --version | /usr/bin/grep -Eq 'Swift version ([6-9]|[1-9][0-9]+)\.'; then
    echo 'Swift 6 or newer is required. Install current Xcode Command Line Tools with xcode-select --install.' >&2
    exit 1
fi
swift build --configuration release
binary="$project_dir/.build/release/displaylink-guard"
"$binary" preflight

# Only one installer per login may manage the permission and installation together.
# A stale directory after SIGKILL/power loss is left for explicit inspection/removal.
install_dir="$HOME/Library/Application Support/DisplayLinkGuard"
mkdir -p "$install_dir"
install_lock="$install_dir/install.lock"
if ! mkdir "$install_lock" 2>/dev/null; then
    echo "Another installation is active, or a previous one was interrupted: $install_lock" >&2
    exit 1
fi
permission_created=false
installation_complete=false
cleanup() {
    result=$?
    trap - EXIT HUP INT TERM
    if [[ "$permission_created" == true && "$installation_complete" != true ]]; then
        if ! sudo /bin/sh "$project_dir/scripts/permission.sh" remove "$(id -u)"; then
            echo "Permission cleanup failed. Remove it manually: sudo rm /private/etc/sudoers.d/displaylink-guard-$(id -u)" >&2
        fi
    fi
    rmdir "$install_lock" || true
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
permission_status=$(sudo /bin/sh "$project_dir/scripts/permission.sh" ensure "$(id -u)")
[[ "$permission_status" != created ]] || permission_created=true
"$binary" install
installation_complete=true
