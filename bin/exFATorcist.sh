#!/bin/sh
set -eu

DEFAULT_LABEL="USB-Stick"
ASK_LABEL=1
MAX_LABEL_LEN=11

REQUIRED_COMMANDS="basename cat cut tr wc id lsblk umount blkdiscard wipefs dd parted partprobe mkfs.exfat sleep"

usage() {
    echo "Usage: $0 [--default-label] /dev/sdX" >&2
    echo >&2
    echo "Formats a whole USB-style block device as exFAT for Windows-compatible use." >&2
    echo >&2
    echo "What this script does:" >&2
    echo "  - refuses to operate on sda" >&2
    echo "  - checks that required commands are installed" >&2
    echo "  - requires root privileges, except for this help output" >&2
    echo "  - shows the current device layout with lsblk" >&2
    echo "  - asks for explicit confirmation before destroying data" >&2
    echo "  - unmounts existing partitions on the target device" >&2
    echo "  - uses blkdiscard if supported, otherwise wipefs plus zeroing the first 16 MiB" >&2
    echo "  - creates a new MBR/msdos partition table" >&2
    echo "  - creates one partition spanning the device" >&2
    echo "  - formats that partition as exFAT" >&2
    echo >&2
    echo "Label handling:" >&2
    echo "  - by default, the script asks interactively for a volume label" >&2
    echo "  - pressing Enter uses the default label: $DEFAULT_LABEL" >&2
    echo "  - entering one single space creates the filesystem without a label" >&2
    echo "  - labels longer than $MAX_LABEL_LEN characters are truncated with a warning" >&2
    echo >&2
    echo "Options:" >&2
    echo "  --default-label   Do not ask for a label; use '$DEFAULT_LABEL'" >&2
    echo "  -h, --help        Show this help" >&2
    echo >&2
    echo "Examples:" >&2
    echo "  $0 /dev/sdb" >&2
    echo "  $0 --default-label /dev/sdb" >&2
}

missing_commands=""

for cmd in $REQUIRED_COMMANDS; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        missing_commands="$missing_commands $cmd"
    fi
done

if [ -n "$missing_commands" ]; then
    echo "Error: required command(s) not found:$missing_commands" >&2
    echo "On Debian, install the likely packages with:" >&2
    echo "  apt install util-linux parted exfatprogs coreutils" >&2
    exit 1
fi

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    usage
    exit 1
fi

case "${1:-}" in
    --default-label)
        ASK_LABEL=0
        shift
        ;;
    -h|--help)
        usage
        exit 0
        ;;
esac

if [ "$#" -ne 1 ]; then
    usage
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: this script must be run as root." >&2
    echo "Run it like this:" >&2
    echo "  sudo $0 [--default-label] /dev/sdX" >&2
    exit 1
fi

DEV="$1"
BASE="$(basename "$DEV")"

if [ "$BASE" = "sda" ]; then
    echo "Refusing to operate on sda" >&2
    exit 1
fi

if [ ! -b "$DEV" ]; then
    echo "Error: $DEV is not a block device" >&2
    exit 1
fi

case "$DEV" in
    /dev/sd[a-z]|/dev/sd[a-z][a-z]|sd[a-z]|sd[a-z][a-z]|./sd[a-z]|./sd[a-z][a-z]|../sd[a-z]|../sd[a-z][a-z])
        ;;
    *)
        echo "Error: only whole /dev/sdX-style devices are accepted" >&2
        echo "Examples: /dev/sdb, sdb, ./sdb" >&2
        echo "Not accepted: /dev/sdb1" >&2
        exit 1
        ;;
esac

LABEL="$DEFAULT_LABEL"
NO_LABEL=0

if [ "$ASK_LABEL" -eq 1 ]; then
    echo
    echo "Enter partition label, max. $MAX_LABEL_LEN characters."
    echo "Press Enter to use default: $DEFAULT_LABEL"
    echo "Enter one single space for no label."
    echo "       ###########"
    printf "label: "
    read -r input_label

    if [ "$input_label" = " " ]; then
        LABEL=""
        NO_LABEL=1
    elif [ -n "$input_label" ]; then
        LABEL="$input_label"
    fi
fi

if [ "$NO_LABEL" -eq 0 ]; then
    LABEL_LEN="$(printf "%s" "$LABEL" | wc -m | tr -d ' ')"

    if [ "$LABEL_LEN" -gt "$MAX_LABEL_LEN" ]; then
        OLD_LABEL="$LABEL"
        LABEL="$(printf "%s" "$LABEL" | cut -c 1-"$MAX_LABEL_LEN")"
        echo "Warning: exFAT label is longer than $MAX_LABEL_LEN characters." >&2
        echo "Warning: truncating label '$OLD_LABEL' to '$LABEL'." >&2
    fi
fi

echo "Target device: $DEV"

if [ "$NO_LABEL" -eq 1 ]; then
    echo "Partition label: none"
else
    echo "Partition label: $LABEL"
fi

echo "Detected layout:"
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MODEL,MOUNTPOINTS "$DEV"

echo
echo "WARNING: all data on $DEV will be destroyed."
printf "Type YES to continue: "
read -r answer

if [ "$answer" != "YES" ]; then
    echo "Aborted."
    exit 1
fi

echo "Unmounting partitions..."
for part in "$DEV"?*; do
    if [ -b "$part" ]; then
        umount "$part" 2>/dev/null || true
    fi
done

DISCARD_MAX="/sys/block/$BASE/queue/discard_max_bytes"

if [ -r "$DISCARD_MAX" ] && [ "$(cat "$DISCARD_MAX")" != "0" ]; then
    echo "Discard supported; running blkdiscard..."
    blkdiscard -v "$DEV"
else
    echo "Discard not supported; using wipefs and zeroing first 16 MiB..."
    wipefs -a "$DEV"
    dd if=/dev/zero of="$DEV" bs=1M count=16 status=progress conv=fsync
fi

echo "Creating MBR partition table..."
parted -s "$DEV" mklabel msdos
parted -s -a optimal "$DEV" mkpart primary 1MiB 100%
partprobe "$DEV"

PART="${DEV}1"

i=0
while [ ! -b "$PART" ] && [ "$i" -lt 10 ]; do
    sleep 1
    i=$((i + 1))
done

if [ ! -b "$PART" ]; then
    echo "Error: partition $PART was not created or not detected" >&2
    exit 1
fi

if [ "$NO_LABEL" -eq 1 ]; then
    echo "Formatting as exFAT without label..."
    mkfs.exfat "$PART"
else
    echo "Formatting as exFAT with label '$LABEL'..."
    mkfs.exfat -L "$LABEL" "$PART"
fi

echo
echo "Done."
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MODEL,MOUNTPOINTS "$DEV"
