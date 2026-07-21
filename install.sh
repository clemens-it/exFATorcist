#!/bin/sh
set -eu

PACKAGE="exFATorcist"
SERVICE_USER="exorcist"
SERVICE_HOME="/home/$SERVICE_USER"
SERVICE_NAME="usb-exorcist-watch.service"
ENABLE_SERVICE=1

usage() {
    cat <<EOF >&2
Usage: sudo sh $0 [--no-enable]

Installs exFATorcist using GNU Stow.

What this installer does:
  - creates the $SERVICE_USER user if it does not exist
  - creates the user's ~/.local/bin and ~/.config/systemd/user directories
  - stows usr/local/sbin and the $SERVICE_USER user files into /
  - validates and installs sudoers/exorcist into /etc/sudoers.d/exorcist
  - enables linger for $SERVICE_USER and tries to enable the user service

Options:
  --no-enable   Install files only; do not enable or start the user service
  -h, --help    Show this help
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-enable)
            ENABLE_SERVICE=0
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

SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd)"
STOW_DIR="$SCRIPT_DIR/stow"
STOW_PACKAGE="$STOW_DIR/$PACKAGE"
SUDOERS_SRC="$SCRIPT_DIR/sudoers/exorcist"
SUDOERS_DST="/etc/sudoers.d/exorcist"
FORMATTER_DST="/usr/local/sbin/exFATorcist"
WATCHER_DST="$SERVICE_HOME/.local/bin/usb-exorcist-watch"

need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Error: required command not found: $1" >&2
        exit 1
    fi
}

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: this installer must be run as root." >&2
    echo "Run it like this:" >&2
    echo "  sudo sh $0" >&2
    exit 1
fi

for cmd in chmod cut getent id install stow visudo; do
    need_cmd "$cmd"
done

if [ ! -d "$STOW_PACKAGE" ]; then
    echo "Error: stow package not found: $STOW_PACKAGE" >&2
    exit 1
fi

if [ ! -f "$SUDOERS_SRC" ]; then
    echo "Error: sudoers source not found: $SUDOERS_SRC" >&2
    exit 1
fi

if ! getent passwd "$SERVICE_USER" >/dev/null 2>&1; then
    need_cmd useradd

    LOGIN_SHELL="/usr/sbin/nologin"
    if [ ! -x "$LOGIN_SHELL" ]; then
        LOGIN_SHELL="/bin/false"
    fi

    useradd --system --create-home --home-dir "$SERVICE_HOME" --shell "$LOGIN_SHELL" "$SERVICE_USER"
fi

USER_HOME="$(getent passwd "$SERVICE_USER" | cut -d: -f6)"
USER_GID="$(getent passwd "$SERVICE_USER" | cut -d: -f4)"

if [ "$USER_HOME" != "$SERVICE_HOME" ]; then
    echo "Error: $SERVICE_USER exists, but its home is $USER_HOME." >&2
    echo "This stow package expects $SERVICE_HOME." >&2
    exit 1
fi

install -d -o "$SERVICE_USER" -g "$USER_GID" -m 0755 \
    "$SERVICE_HOME" \
    "$SERVICE_HOME/.local" \
    "$SERVICE_HOME/.local/bin" \
    "$SERVICE_HOME/.config" \
    "$SERVICE_HOME/.config/systemd" \
    "$SERVICE_HOME/.config/systemd/user"

install -d -o root -g root -m 0755 /usr/local/sbin /etc/sudoers.d

stow -d "$STOW_DIR" -t / --restow "$PACKAGE"

chmod 0755 "$FORMATTER_DST" "$WATCHER_DST"

TMP_SUDOERS="${TMPDIR:-/tmp}/exorcist-sudoers.$$"
trap 'rm -f "$TMP_SUDOERS"' EXIT HUP INT TERM

install -o root -g root -m 0440 "$SUDOERS_SRC" "$TMP_SUDOERS"
visudo -cf "$TMP_SUDOERS" >/dev/null
install -o root -g root -m 0440 "$SUDOERS_SRC" "$SUDOERS_DST"
visudo -cf "$SUDOERS_DST" >/dev/null

enable_user_service() {
    if ! command -v systemctl >/dev/null 2>&1; then
        echo "Warning: systemctl not found; service installed but not enabled." >&2
        return 0
    fi

    if command -v loginctl >/dev/null 2>&1; then
        loginctl enable-linger "$SERVICE_USER" || {
            echo "Warning: could not enable linger for $SERVICE_USER." >&2
            return 0
        }
    fi

    USER_UID="$(id -u "$SERVICE_USER")"
    RUNTIME_DIR="/run/user/$USER_UID"

    systemctl start "user@$USER_UID.service" >/dev/null 2>&1 || true

    if ! command -v runuser >/dev/null 2>&1 || [ ! -d "$RUNTIME_DIR" ]; then
        echo "Warning: user systemd manager is not reachable yet." >&2
        echo "Service file was installed at $SERVICE_HOME/.config/systemd/user/$SERVICE_NAME." >&2
        return 0
    fi

    if ! runuser -u "$SERVICE_USER" -- env \
        XDG_RUNTIME_DIR="$RUNTIME_DIR" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNTIME_DIR/bus" \
        systemctl --user daemon-reload; then
        echo "Warning: could not reload the $SERVICE_USER user systemd manager." >&2
        return 0
    fi

    if ! runuser -u "$SERVICE_USER" -- env \
        XDG_RUNTIME_DIR="$RUNTIME_DIR" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNTIME_DIR/bus" \
        systemctl --user enable --now "$SERVICE_NAME"; then
        echo "Warning: service installed, but enabling $SERVICE_NAME failed." >&2
        return 0
    fi
}

if [ "$ENABLE_SERVICE" -eq 1 ]; then
    enable_user_service
fi

echo "Installed $PACKAGE."
