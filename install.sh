#!/bin/sh
set -eu

PACKAGE="exFATorcist"
SERVICE_USER="exorcist"
SERVICE_HOME="/home/$SERVICE_USER"
WATCH_SERVICE_NAME="usb-exorcist-watch.service"
WATCH_TTY_NAME="tty2"
DIAGNOSTIC_SERVICE_NAME="kernel-diagnostics.service"
DIAGNOSTIC_TTY_NAME="tty8"
ENABLE_SERVICES=1

usage() {
    cat <<EOF >&2
Usage: sudo sh $0 [--no-enable]

Installs exFATorcist on /dev/$WATCH_TTY_NAME with kernel diagnostics on
/dev/$DIAGNOSTIC_TTY_NAME.

What this installer does:
  - creates the $SERVICE_USER user if it does not exist
  - stows the formatter and watcher into /
  - copies both systemd services into /etc/systemd/system
  - validates and installs sudoers/exorcist into /etc/sudoers.d/exorcist
  - suppresses kernel messages below error priority on normal consoles
  - reserves $WATCH_TTY_NAME for the watcher and $DIAGNOSTIC_TTY_NAME for diagnostics
  - enables and starts both services

Options:
  --no-enable   Install files only; do not reserve TTYs or start services
  -h, --help    Show this help
EOF
}

# Parse installer mode before deriving paths or touching system state.
while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-enable)
            ENABLE_SERVICES=0
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

# Resolve paths relative to this script so installation works from any cwd.
SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd)"
STOW_DIR="$SCRIPT_DIR/stow"
STOW_PACKAGE="$STOW_DIR/$PACKAGE"
SUDOERS_SRC="$SCRIPT_DIR/sudoers/exorcist"
SUDOERS_DST="/etc/sudoers.d/exorcist"
WATCH_SERVICE_SRC="$SCRIPT_DIR/systemd/$WATCH_SERVICE_NAME"
DIAGNOSTIC_SERVICE_SRC="$SCRIPT_DIR/systemd/$DIAGNOSTIC_SERVICE_NAME"
FORMATTER_DST="/usr/local/sbin/exFATorcist"
WATCHER_DST="$SERVICE_HOME/.local/bin/usb-exorcist-watch"
WATCH_SERVICE_DST="/etc/systemd/system/$WATCH_SERVICE_NAME"
DIAGNOSTIC_SERVICE_DST="/etc/systemd/system/$DIAGNOSTIC_SERVICE_NAME"
SYSCTL_SRC="$SCRIPT_DIR/sysctl/90-exFATorcist-console.conf"
SYSCTL_DST="/etc/sysctl.d/90-exFATorcist-console.conf"
STATE_DIR="/var/lib/exFATorcist"
PRINTK_STATE="$STATE_DIR/kernel.printk"

# Keep dependency errors close to the command that will need them.
need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Error: required command not found: $1" >&2
        exit 1
    fi
}

# Installing system files, users, sudoers entries, and services requires root.
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: this installer must be run as root." >&2
    echo "Run it like this:" >&2
    echo "  sudo sh $0" >&2
    exit 1
fi

# Check the common toolchain up front; service management is checked later.
for cmd in cat chmod cut getent id install rm stow visudo; do
    need_cmd "$cmd"
done

# Refuse to continue if the source tree is incomplete.
if [ ! -d "$STOW_PACKAGE" ]; then
    echo "Error: stow package not found: $STOW_PACKAGE" >&2
    exit 1
fi

if [ ! -f "$SUDOERS_SRC" ]; then
    echo "Error: sudoers source not found: $SUDOERS_SRC" >&2
    exit 1
fi

if [ ! -f "$WATCH_SERVICE_SRC" ]; then
    echo "Error: systemd service source not found: $WATCH_SERVICE_SRC" >&2
    exit 1
fi

if [ ! -f "$DIAGNOSTIC_SERVICE_SRC" ]; then
    echo "Error: systemd service source not found: $DIAGNOSTIC_SERVICE_SRC" >&2
    exit 1
fi

if [ ! -f "$SYSCTL_SRC" ]; then
    echo "Error: sysctl source not found: $SYSCTL_SRC" >&2
    exit 1
fi

# Create a dedicated non-login account for the tty-bound system service.
LOGIN_SHELL="/bin/false"
if [ -x /usr/sbin/nologin ]; then
    LOGIN_SHELL="/usr/sbin/nologin"
fi

if ! getent passwd "$SERVICE_USER" >/dev/null 2>&1; then
    need_cmd useradd
    useradd --system --create-home --home-dir "$SERVICE_HOME" --shell "$LOGIN_SHELL" "$SERVICE_USER"
fi

# Cache passwd data used for ownership checks.
USER_HOME="$(getent passwd "$SERVICE_USER" | cut -d: -f6)"
USER_GID="$(getent passwd "$SERVICE_USER" | cut -d: -f4)"
USER_SHELL="$(getent passwd "$SERVICE_USER" | cut -d: -f7)"

# The stow package hardcodes /home/exorcist, so do not silently install elsewhere.
if [ "$USER_HOME" != "$SERVICE_HOME" ]; then
    echo "Error: $SERVICE_USER exists, but its home is $USER_HOME." >&2
    echo "This stow package expects $SERVICE_HOME." >&2
    exit 1
fi

# The new tty2 service does not need an interactive login shell.
if [ "$USER_SHELL" != "$LOGIN_SHELL" ]; then
    need_cmd usermod
    usermod --shell "$LOGIN_SHELL" "$SERVICE_USER"
fi

# Prepare the directories that stow will populate with symlinks.
install -d -o "$SERVICE_USER" -g "$USER_GID" -m 0755 \
    "$SERVICE_HOME" \
    "$SERVICE_HOME/.local" \
    "$SERVICE_HOME/.local/bin"

install -d -o root -g root -m 0755 \
    /usr/local/sbin \
    /etc/sudoers.d \
    /etc/systemd/system \
    /etc/sysctl.d \
    "$STATE_DIR"

# Deploy the package symlinks into their final absolute locations.
stow -d "$STOW_DIR" -t / --restow "$PACKAGE"

# Make executable targets executable even when the checkout loses mode bits.
chmod 0755 "$FORMATTER_DST" "$WATCHER_DST"

# Root-managed configuration should remain available independently of the checkout.
install -o root -g root -m 0644 "$WATCH_SERVICE_SRC" "$WATCH_SERVICE_DST"
install -o root -g root -m 0644 "$DIAGNOSTIC_SERVICE_SRC" "$DIAGNOSTIC_SERVICE_DST"

# Preserve the host's live console policy once so uninstall can restore it.
if [ ! -f "$PRINTK_STATE" ]; then
    if [ ! -r /proc/sys/kernel/printk ]; then
        echo "Error: cannot read the current kernel.printk setting." >&2
        exit 1
    fi

    PRINTK_CURRENT="$(cat /proc/sys/kernel/printk)"
    printf '%s\n' "$PRINTK_CURRENT" > "$PRINTK_STATE"
    chmod 0600 "$PRINTK_STATE"
fi

# systemd-sysctl loads this policy at boot; normal installs also apply it below.
install -o root -g root -m 0644 "$SYSCTL_SRC" "$SYSCTL_DST"

# Temporary files keep sudoers updates atomic enough for installer use.
TMP_SUDOERS="${TMPDIR:-/tmp}/exorcist-sudoers.$$"
trap 'rm -f "$TMP_SUDOERS"' EXIT HUP INT TERM

# Validate sudoers before and after installing the root-owned fragment.
install -o root -g root -m 0440 "$SUDOERS_SRC" "$TMP_SUDOERS"
visudo -cf "$TMP_SUDOERS" >/dev/null
install -o root -g root -m 0440 "$SUDOERS_SRC" "$SUDOERS_DST"
visudo -cf "$SUDOERS_DST" >/dev/null

reserve_tty() {
    # Stop and mask both common getty names for the requested virtual terminal.
    need_cmd systemctl

    RESERVED_TTY="$1"

    for unit in "getty@$RESERVED_TTY.service" "autovt@$RESERVED_TTY.service"; do
        systemctl stop "$unit" >/dev/null 2>&1 || true
        systemctl mask "$unit" >/dev/null 2>&1 || {
            echo "Warning: could not mask $unit." >&2
        }
    done
}

enable_system_services() {
    # Reserve both TTYs, apply the console policy, and start their services.
    need_cmd systemctl
    need_cmd journalctl
    need_cmd sysctl

    systemctl daemon-reload
    reserve_tty "$WATCH_TTY_NAME"
    reserve_tty "$DIAGNOSTIC_TTY_NAME"
    sysctl -p "$SYSCTL_DST" >/dev/null
    systemctl enable "$WATCH_SERVICE_NAME" "$DIAGNOSTIC_SERVICE_NAME"
    systemctl restart "$WATCH_SERVICE_NAME" "$DIAGNOSTIC_SERVICE_NAME"
}

if [ "$ENABLE_SERVICES" -eq 1 ]; then
    enable_system_services
else
    echo "Installed files only; services and TTY reservations were not activated." >&2
    echo "Activate later by rerunning: sudo sh $0" >&2
fi

echo "Installed $PACKAGE."
