#!/bin/sh
set -eu

PACKAGE="exFATorcist"
SERVICE_USER="exorcist"
SERVICE_HOME="/home/$SERVICE_USER"
SERVICE_NAME="usb-exorcist-watch.service"
TTY_NAME="tty2"
TTY_GETTY_UNITS="getty@$TTY_NAME.service autovt@$TTY_NAME.service"
REMOVE_USER=0

usage() {
    cat <<EOF >&2
Usage: sudo sh $0 [--remove-user]

Uninstalls exFATorcist from this machine.

What this uninstaller does:
  - disables and stops $SERVICE_NAME
  - removes legacy tty1 profile/user-service autostart hooks if present
  - removes /etc/sudoers.d/exorcist
  - unstows the exFATorcist package from /
  - unmasks the normal login getty on $TTY_NAME

Options:
  --remove-user  Also remove the $SERVICE_USER user and its home directory
  -h, --help     Show this help
EOF
}

# Parse removal policy before touching system state.
while [ "$#" -gt 0 ]; do
    case "$1" in
        --remove-user)
            REMOVE_USER=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage
            exit 1
            ;;
    esac

    shift
done

# Resolve the stow source tree relative to the uninstaller.
SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd)"
STOW_DIR="$SCRIPT_DIR/stow"
SUDOERS_DST="/etc/sudoers.d/exorcist"
SYSTEM_SERVICE_DST="/etc/systemd/system/$SERVICE_NAME"
LEGACY_PROFILE_DST="$SERVICE_HOME/.profile"
LEGACY_FG_WATCHER_DST="$SERVICE_HOME/.local/bin/usb-exorcist-watch-fg"
LEGACY_USER_SERVICE_DST="$SERVICE_HOME/.config/systemd/user/$SERVICE_NAME"

# Keep dependency failures explicit and early.
need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Error: required command not found: $1" >&2
        exit 1
    fi
}

# Removing sudoers entries, services, stow links, and users requires root.
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: this uninstaller must be run as root." >&2
    echo "Run it like this:" >&2
    echo "  sudo sh $0" >&2
    exit 1
fi

# These are the base commands needed before optional user deletion.
for cmd in cut getent id install rm sed stow; do
    need_cmd "$cmd"
done

# Reused when removing the legacy managed .profile block.
TMP_PROFILE="${TMPDIR:-/tmp}/exorcist-profile-uninstall.$$"
trap 'rm -f "$TMP_PROFILE"' EXIT HUP INT TERM

disable_system_service() {
    # Stop the tty2 watcher before removing its unit symlink.
    if ! command -v systemctl >/dev/null 2>&1; then
        return 0
    fi

    systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
}

release_tty() {
    # Undo the tty reservation so a normal login can use tty2 again.
    if ! command -v systemctl >/dev/null 2>&1; then
        return 0
    fi

    for unit in $TTY_GETTY_UNITS; do
        systemctl unmask "$unit" >/dev/null 2>&1 || true
    done

    systemctl daemon-reload
    systemctl enable --now "getty@$TTY_NAME.service" >/dev/null 2>&1 || {
        echo "Warning: could not restore getty@$TTY_NAME.service." >&2
    }
}

remove_legacy_profile_autostart() {
    # Remove only the old block managed by install.sh, preserving local edits.
    if [ ! -f "$LEGACY_PROFILE_DST" ]; then
        return 0
    fi

    sed '/^# BEGIN exFATorcist tty1 autostart$/,/^# END exFATorcist tty1 autostart$/d' \
        "$LEGACY_PROFILE_DST" > "$TMP_PROFILE"
    install -o "$SERVICE_USER" -g "$USER_GID" -m 0644 "$TMP_PROFILE" "$LEGACY_PROFILE_DST"
}

run_legacy_user_systemctl() {
    # Best-effort cleanup for the previous systemd user-service design.
    if ! command -v runuser >/dev/null 2>&1 || [ ! -d "$USER_RUNTIME_DIR" ]; then
        return 1
    fi

    runuser -u "$SERVICE_USER" -- env \
        XDG_RUNTIME_DIR="$USER_RUNTIME_DIR" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$USER_RUNTIME_DIR/bus" \
        systemctl --user "$@"
}

remove_legacy_user_service() {
    # Old installs used a user service, a foreground wrapper, and linger.
    if command -v systemctl >/dev/null 2>&1; then
        systemctl start "user@$USER_UID.service" >/dev/null 2>&1 || true
        run_legacy_user_systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
        run_legacy_user_systemctl daemon-reload >/dev/null 2>&1 || true
    fi

    if command -v loginctl >/dev/null 2>&1; then
        loginctl disable-linger "$SERVICE_USER" >/dev/null 2>&1 || true
    fi

    rm -f "$LEGACY_FG_WATCHER_DST" "$LEGACY_USER_SERVICE_DST"
}

disable_system_service

# User-specific cleanup is skipped if the dedicated account is already gone.
if getent passwd "$SERVICE_USER" >/dev/null 2>&1; then
    USER_GID="$(getent passwd "$SERVICE_USER" | cut -d: -f4)"
    USER_UID="$(id -u "$SERVICE_USER")"
    USER_RUNTIME_DIR="/run/user/$USER_UID"

    remove_legacy_profile_autostart
    remove_legacy_user_service
fi

# Remove installed root-owned files that are copied rather than stowed.
rm -f "$SUDOERS_DST" "$SYSTEM_SERVICE_DST"

# Delete the package symlinks that were previously created under /.
if [ -d "$STOW_DIR/$PACKAGE" ]; then
    stow -d "$STOW_DIR" -t / --delete "$PACKAGE" || {
        echo "Warning: stow could not remove all $PACKAGE symlinks." >&2
    }
fi

release_tty

# Account removal is opt-in because it deletes the user's home directory.
if [ "$REMOVE_USER" -eq 1 ] && getent passwd "$SERVICE_USER" >/dev/null 2>&1; then
    need_cmd userdel
    userdel -r "$SERVICE_USER"
fi

echo "Uninstalled $PACKAGE."
