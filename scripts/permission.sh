#!/bin/sh
# Invoked by install.sh with sudo. Never grant root access to this script itself.
set -eu
[ "$(id -u)" = 0 ] || { echo 'Administrator privileges required.' >&2; exit 1; }
[ "$#" = 2 ] || exit 1
operation=$1
target_uid=$2
case "$target_uid" in ''|0|*[!0-9]*) exit 1 ;; esac
case "$operation" in ensure|remove) ;; *) exit 1 ;; esac
rule_path="/private/etc/sudoers.d/displaylink-guard-$target_uid"
mkdir -p /private/etc/sudoers.d
rule=$(mktemp /private/etc/sudoers.d/.displaylink-guard.XXXXXX)
trap 'rm -f "$rule"' EXIT HUP INT TERM
printf '#%s ALL=(root) NOPASSWD: /bin/launchctl kickstart -k system/com.displaylink.DisplayLinkManager.PrivilegedHelper\n' "$target_uid" > "$rule"
chown root:wheel "$rule"
chmod 0440 "$rule"
/usr/sbin/visudo -cf "$rule" >&2
if [ -e "$rule_path" ] || [ -L "$rule_path" ]; then
    if [ -L "$rule_path" ] || [ ! -f "$rule_path" ] || ! cmp -s "$rule" "$rule_path"; then
        echo "Refusing to modify an unexpected permission file: $rule_path" >&2
        exit 1
    fi
    if [ "$operation" = remove ]; then
        rm "$rule_path"
    else
        # Validate the existing file's ownership and mode, not just its contents.
        [ "$(stat -f '%u:%Lp' "$rule_path")" = '0:440' ] || {
            echo "Unexpected ownership or mode on $rule_path" >&2
            exit 1
        }
        printf 'existing\n'
    fi
elif [ "$operation" = ensure ]; then
    mv "$rule" "$rule_path"
    printf 'created\n'
fi
