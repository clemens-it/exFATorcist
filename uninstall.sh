#!/bin/sh
set -eu

PACKAGE="exFATorcist"
SERVICE_USER="exorcist"
WATCH_SERVICE_NAME="usb-exorcist-watch.service"
WATCH_TTY_NAME="tty2"
DIAGNOSTIC_SERVICE_NAME="kernel-diagnostics.service"
DIAGNOSTIC_TTY_NAME="tty8"
REMOVE_USER=0

usage() {
    cat <<EOF >&2
Usage: sudo sh $0 [--remove-user]

Uninstalls exFATorcist from this machine.

What this uninstaller does:
  - disables and stops both system services
  - removes the installed sudoers, systemd, and sysctl files
  - unstows the exFATorcist package from /
  - restores the previous live kernel console policy
  - releases $WATCH_TTY_NAME and $DIAGNOSTIC_TTY_NAME

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
WATCH_SERVICE_DST="/etc/systemd/system/$WATCH_SERVICE_NAME"
DIAGNOSTIC_SERVICE_DST="/etc/systemd/system/$DIAGNOSTIC_SERVICE_NAME"
SYSCTL_DST="/etc/sysctl.d/90-exFATorcist-console.conf"
STATE_DIR="/var/lib/exFATorcist"
PRINTK_STATE="$STATE_DIR/kernel.printk"

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
for cmd in cat getent id rm rmdir stow; do
    need_cmd "$cmd"
done

disable_system_services() {
    # Stop both TTY owners before removing their copied unit files.
    if ! command -v systemctl >/dev/null 2>&1; then
        return 0
    fi

    systemctl disable --now \
        "$WATCH_SERVICE_NAME" \
        "$DIAGNOSTIC_SERVICE_NAME" >/dev/null 2>&1 || true
}

release_tty() {
    # Undo one TTY reservation and optionally restore a permanent login getty.
    if ! command -v systemctl >/dev/null 2>&1; then
        return 0
    fi

    RELEASED_TTY="$1"
    RESTORE_GETTY="$2"

    for unit in "getty@$RELEASED_TTY.service" "autovt@$RELEASED_TTY.service"; do
        systemctl unmask "$unit" >/dev/null 2>&1 || true
    done

    if [ "$RESTORE_GETTY" -eq 1 ]; then
        systemctl enable --now "getty@$RELEASED_TTY.service" >/dev/null 2>&1 || {
            echo "Warning: could not restore getty@$RELEASED_TTY.service." >&2
        }
    fi
}

restore_console_policy() {
    # Put the live printk threshold back to the value saved during installation.
    if [ ! -f "$PRINTK_STATE" ]; then
        return 0
    fi

    if ! command -v sysctl >/dev/null 2>&1; then
        echo "Warning: sysctl is unavailable; $PRINTK_STATE was kept." >&2
        return 0
    fi

    SAVED_PRINTK="$(cat "$PRINTK_STATE")"
    if sysctl -w "kernel.printk=$SAVED_PRINTK" >/dev/null; then
        rm -f "$PRINTK_STATE"
        rmdir "$STATE_DIR" >/dev/null 2>&1 || true
    else
        echo "Warning: kernel.printk could not be restored; $PRINTK_STATE was kept." >&2
    fi
}

disable_system_services

# Remove installed root-owned files that are copied rather than stowed.
rm -f \
    "$SUDOERS_DST" \
    "$WATCH_SERVICE_DST" \
    "$DIAGNOSTIC_SERVICE_DST" \
    "$SYSCTL_DST"

# Delete the package symlinks that were previously created under /.
if [ -d "$STOW_DIR/$PACKAGE" ]; then
    stow -d "$STOW_DIR" -t / --delete "$PACKAGE" || {
        echo "Warning: stow could not remove all $PACKAGE symlinks." >&2
    }
fi

# Reload unit discovery before returning both virtual terminals to normal use.
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload
fi

release_tty "$WATCH_TTY_NAME" 1
release_tty "$DIAGNOSTIC_TTY_NAME" 0
restore_console_policy

# Account removal is opt-in because it deletes the user's home directory.
if [ "$REMOVE_USER" -eq 1 ] && getent passwd "$SERVICE_USER" >/dev/null 2>&1; then
    need_cmd userdel
    userdel -r "$SERVICE_USER"
fi

echo "Uninstalled $PACKAGE."
