#!/usr/bin/env bash
# Thumbelina — Linux format helper (also usable from a helper VM).
# Reads format-plan.json in the same directory, or accepts flags.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAN="${DIR}/format-plan.json"

DEVICE=""
MODE="live-iso"
LABEL="Thumbelina"
EXFAT_BYTES=0
ESP_BYTES=$((512 * 1024 * 1024))
INSTANCE_ID="helper"

if [[ -f "$PLAN" ]]; then
  # minimal JSON scrape without jq dependency
  DEVICE=$(sed -n 's/.*"device"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$PLAN" | head -1)
  MODE=$(sed -n 's/.*"mode"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$PLAN" | head -1)
  LABEL=$(sed -n 's/.*"label"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$PLAN" | head -1)
  EXFAT_BYTES=$(sed -n 's/.*"exfatBytes"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$PLAN" | head -1)
  ESP_BYTES=$(sed -n 's/.*"espBytes"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$PLAN" | head -1)
  INSTANCE_ID=$(sed -n 's/.*"instanceId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$PLAN" | head -1)
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    --exfat-bytes) EXFAT_BYTES="$2"; shift 2 ;;
    --yes) shift ;;
    *) echo "Unknown arg: $1"; exit 2 ;;
  esac
done

if [[ -z "$DEVICE" || ! -b "$DEVICE" ]]; then
  echo "Refusing: DEVICE must be a block device (got: ${DEVICE:-empty})"
  exit 1
fi

need() { command -v "$1" >/dev/null || { echo "Missing tool: $1"; exit 1; }; }
need wipefs
need sgdisk
need partprobe
need mkfs.vfat
need mkfs.exfat
need mount

HAS_BTRFS=0
case "$MODE" in
  installed|both) HAS_BTRFS=1; need mkfs.btrfs; need btrfs ;;
esac

ESP_MIB=$((ESP_BYTES / 1024 / 1024))
[[ "$ESP_MIB" -lt 100 ]] && ESP_MIB=512

echo "Wiping $DEVICE mode=$MODE"
wipefs -a "$DEVICE"
sgdisk --zap-all "$DEVICE"

part_suffix() {
  local d="$1" n="$2"
  if [[ "$d" == *nvme* || "$d" == *mmcblk* || "$d" == *loop* ]]; then
    echo "${d}p${n}"
  else
    echo "${d}${n}"
  fi
}

sgdisk -n "1:0:+${ESP_MIB}M" -t 1:EF00 -c 1:THUMBELINA-EFI "$DEVICE"
if [[ "$MODE" == "live-iso" ]]; then
  sgdisk -n 2:0:0 -t 2:0700 -c 2:"$LABEL" "$DEVICE"
elif [[ "$MODE" == "installed" ]]; then
  sgdisk -n 2:0:+256M -t 2:0700 -c 2:"$LABEL" "$DEVICE"
  sgdisk -n 3:0:0 -t 3:8300 -c 3:THUMBELINA-POOL "$DEVICE"
else
  EXFAT_MIB=$((EXFAT_BYTES / 1024 / 1024))
  [[ "$EXFAT_MIB" -lt 1024 ]] && EXFAT_MIB=32768
  sgdisk -n "2:0:+${EXFAT_MIB}M" -t 2:0700 -c 2:"$LABEL" "$DEVICE"
  sgdisk -n 3:0:0 -t 3:8300 -c 3:THUMBELINA-POOL "$DEVICE"
fi

partprobe "$DEVICE"
sleep 1
ESP=$(part_suffix "$DEVICE" 1)
EXFAT=$(part_suffix "$DEVICE" 2)
BTRFS=""
[[ "$HAS_BTRFS" -eq 1 ]] && BTRFS=$(part_suffix "$DEVICE" 3)

mkfs.vfat -F 32 -n THUMBELINA-EFI "$ESP"
# truncate label to 11 chars for exFAT
LABELY=${LABEL:0:11}
mkfs.exfat -n "$LABELY" "$EXFAT"
if [[ -n "$BTRFS" ]]; then
  mkfs.btrfs -f -L THUMBELINA-POOL "$BTRFS"
fi

WORKDIR=$(mktemp -d)
cleanup() {
  umount "$WORKDIR/esp" 2>/dev/null || true
  umount "$WORKDIR/exfat" 2>/dev/null || true
  umount "$WORKDIR/btrfs" 2>/dev/null || true
  rmdir "$WORKDIR/esp" "$WORKDIR/exfat" "$WORKDIR/btrfs" 2>/dev/null || true
  rmdir "$WORKDIR" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$WORKDIR/esp" "$WORKDIR/exfat"
mount "$ESP" "$WORKDIR/esp"
mount "$EXFAT" "$WORKDIR/exfat"
mkdir -p "$WORKDIR/exfat/isos" "$WORKDIR/exfat/docs" "$WORKDIR/exfat/tools"
cat > "$WORKDIR/exfat/README.txt" <<EOF
Thumbelina
Mode: $MODE
Instance: $INSTANCE_ID
Prepared by linux-format.sh helper.
EOF
cat > "$WORKDIR/exfat/VERSION.txt" <<EOF
mode=$MODE
instance=$INSTANCE_ID
EOF

if [[ -n "$BTRFS" ]]; then
  mkdir -p "$WORKDIR/btrfs"
  mount "$BTRFS" "$WORKDIR/btrfs"
  btrfs subvolume create "$WORKDIR/btrfs/@shared_home"
  btrfs property set "$WORKDIR/btrfs" compression zstd || true
fi

mkdir -p "$WORKDIR/esp/EFI/BOOT" "$WORKDIR/esp/boot/grub" "$WORKDIR/esp/EFI/thumbdrive-multiboot"
CFG="$WORKDIR/esp/boot/grub/grub.cfg"
{
  echo "set timeout=15"
  echo "set default=0"
  echo "insmod part_gpt"
  echo "insmod fat"
  echo "insmod exfat"
  echo "insmod iso9660"
  echo "insmod loopback"
  echo "insmod btrfs"
  echo "menuentry \"Thumbelina — scan ISOs from file system\" {"
  echo "  echo Drop ISOs into isos/ then regenerate menu with thumbelina refresh-boot"
  echo "  sleep 3"
  echo "}"
} > "$CFG"
cp "$CFG" "$WORKDIR/esp/EFI/BOOT/grub.cfg"
cp "$CFG" "$WORKDIR/esp/EFI/thumbdrive-multiboot/grub.cfg"

if command -v grub-install >/dev/null; then
  grub-install --target=x86_64-efi --efi-directory="$WORKDIR/esp" \
    --boot-directory="$WORKDIR/esp/boot" --removable --recheck "$DEVICE"
elif command -v grub2-install >/dev/null; then
  grub2-install --target=x86_64-efi --efi-directory="$WORKDIR/esp" \
    --boot-directory="$WORKDIR/esp/boot" --removable --recheck "$DEVICE"
else
  echo "NOTE: grub-install missing; ESP has grub.cfg only. Install GRUB EFI later."
fi

echo "OK formatted $DEVICE as $MODE"
