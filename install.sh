#!/bin/sh
set -eu

PACKAGE="exFATorcist"
SERVICE_USER="exorcist"
SERVICE_HOME="/home/$SERVICE_USER"
SERVICE_NAME="usb-exorcist-watch.service"
TTY_NAME="tty2"
TTY_GETTY_UNITS="getty@$TTY_NAME.service autovt@$TTY_NAME.service"
ENABLE_SERVICE=1

usage() {
    cat <<EOF >&2
Usage: sudo sh $0 [--no-enable]

Installs exFATorcist as a system service on /dev/$TTY_NAME.

What this installer does:
  - creates the $SERVICE_USER user if it does not exist
  - stows the formatter and watcher into /
  - copies the systemd service into /etc/systemd/system
  - validates and installs sudoers/exorcist into /etc/sudoers.d/exorcist
  - removes legacy tty1 profile/user-service autostart hooks
  - disables the normal login getty on $TTY_NAME
  - enables and starts $SERVICE_NAME

Options:
  --no-enable   Install files only; do not reserve $TTY_NAME or start the service
  -h, --help    Show this help
EOF
}

# Parse installer mode before deriving paths or touching system state.
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

# Resolve paths relative to this script so installation works from any cwd.
SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd)"
STOW_DIR="$SCRIPT_DIR/stow"
STOW_PACKAGE="$STOW_DIR/$PACKAGE"
SUDOERS_SRC="$SCRIPT_DIR/sudoers/exorcist"
SUDOERS_DST="/etc/sudoers.d/exorcist"
SYSTEM_SERVICE_SRC="$SCRIPT_DIR/systemd/$SERVICE_NAME"
FORMATTER_DST="/usr/local/sbin/exFATorcist"
WATCHER_DST="$SERVICE_HOME/.local/bin/usb-exorcist-watch"
SYSTEM_SERVICE_DST="/etc/systemd/system/$SERVICE_NAME"
LEGACY_PROFILE_DST="$SERVICE_HOME/.profile"
LEGACY_FG_WATCHER_DST="$SERVICE_HOME/.local/bin/usb-exorcist-watch-fg"
LEGACY_USER_SERVICE_DST="$SERVICE_HOME/.config/systemd/user/$SERVICE_NAME"

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
for cmd in cat chmod cut getent id install rm sed stow visudo; do
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

if [ ! -f "$SYSTEM_SERVICE_SRC" ]; then
    echo "Error: systemd service source not found: $SYSTEM_SERVICE_SRC" >&2
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

# Cache passwd data used for ownership checks and legacy cleanup.
USER_HOME="$(getent passwd "$SERVICE_USER" | cut -d: -f6)"
USER_GID="$(getent passwd "$SERVICE_USER" | cut -d: -f4)"
USER_UID="$(id -u "$SERVICE_USER")"
USER_SHELL="$(getent passwd "$SERVICE_USER" | cut -d: -f7)"
USER_RUNTIME_DIR="/run/user/$USER_UID"

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
    /etc/systemd/system

# Deploy the package symlinks into their final absolute locations.
stow -d "$STOW_DIR" -t / --restow "$PACKAGE"

# Make executable targets executable even when the checkout loses mode bits.
chmod 0755 "$FORMATTER_DST" "$WATCHER_DST"

# System units should be real root-owned files, not symlinks to a checkout.
install -o root -g root -m 0644 "$SYSTEM_SERVICE_SRC" "$SYSTEM_SERVICE_DST"

# Temporary files keep sudoers/profile cleanup atomic enough for installer use.
TMP_SUDOERS="${TMPDIR:-/tmp}/exorcist-sudoers.$$"
TMP_PROFILE="${TMPDIR:-/tmp}/exorcist-profile.$$"
trap 'rm -f "$TMP_SUDOERS" "$TMP_PROFILE"' EXIT HUP INT TERM

# Validate sudoers before and after installing the root-owned fragment.
install -o root -g root -m 0440 "$SUDOERS_SRC" "$TMP_SUDOERS"
visudo -cf "$TMP_SUDOERS" >/dev/null
install -o root -g root -m 0440 "$SUDOERS_SRC" "$SUDOERS_DST"
visudo -cf "$SUDOERS_DST" >/dev/null

remove_legacy_profile_autostart() {
    # Delete only the old managed block and leave user-authored profile content alone.
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

reserve_tty() {
    # Mask both common getty instance names so tty2 belongs to this service.
    need_cmd systemctl

    for unit in $TTY_GETTY_UNITS; do
        systemctl stop "$unit" >/dev/null 2>&1 || true
        systemctl disable "$unit" >/dev/null 2>&1 || true
        systemctl mask "$unit" >/dev/null 2>&1 || {
            echo "Warning: could not mask $unit." >&2
        }
    done
}

enable_system_service() {
    # Reload units after stowing, reserve tty2, then start the watcher service.
    need_cmd systemctl

    systemctl daemon-reload
    reserve_tty
    systemctl enable "$SERVICE_NAME"
    systemctl restart "$SERVICE_NAME"
}

# Remove leftovers from earlier autostart concepts before activating the new one.
remove_legacy_profile_autostart
remove_legacy_user_service

if [ "$ENABLE_SERVICE" -eq 1 ]; then
    enable_system_service
else
    echo "Installed files only; $SERVICE_NAME was not enabled." >&2
    echo "Enable later with: sudo systemctl enable --now $SERVICE_NAME" >&2
fi

echo "Installed $PACKAGE."
