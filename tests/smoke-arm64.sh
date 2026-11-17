#!/bin/bash
# arm64 VM image test in QEMU (KVM when present, else TCG):
#   1. Boot the image; answer the first-boot PIN and time zone prompts.
#   2. Wait until Intent's window is on screen (INTENT_OS_BOOT_OK on serial).
#   3. Screenshot the lock screen, type the PIN, screenshot again.
# Artifacts: boot.log, locked.png, unlocked.png, boot-latest.png, result.txt.
# Needs: qemu-system-aarch64, AArch64 UEFI firmware, socat, ImageMagick.
set -euo pipefail

IMG=${1:?usage: tests/smoke-arm64.sh <qcow2> [out-dir]}
OUT=${2:-out/smoke}
PIN=2468
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

find_first() {
  local f
  for f in "$@"; do [[ -f $f ]] && { echo "$f"; return; }; done
  return 1
}
FIRMWARE=$(find_first /usr/share/qemu-efi-aarch64/QEMU_EFI.fd /usr/share/edk2/aarch64/QEMU_EFI.fd \
  /usr/share/AAVMF/AAVMF_CODE.fd)

result() { echo "$1" | tee "$OUT/result.txt"; }
fail() { result "FAIL: $1"; exit 1; }

accel=(-accel tcg -cpu max)
slow=3
if [[ -w /dev/kvm ]]; then
  accel=(-accel kvm -cpu host)
  slow=1
fi

cp "$IMG" "$OUT/disk.qcow2"
MON=$OUT/monitor.sock
rm -f "$MON"
# shellcheck disable=SC2054
qemu-system-aarch64 -M virt "${accel[@]}" -smp 4 -m 4096 -bios "$FIRMWARE" \
  -drive "file=$OUT/disk.qcow2,if=virtio,format=qcow2" \
  -device virtio-gpu-pci -device qemu-xhci -device usb-kbd -device usb-tablet \
  -nic user,model=virtio-net-pci -display none \
  -serial "file:$OUT/boot.log" -monitor "unix:$MON,server,nowait" &
QEMU_PID=$!
trap 'kill "$QEMU_PID" 2>/dev/null || true' EXIT

# Keep the connection open briefly: QEMU drops a command whose client hangs up at once.
monitor() { { echo "$1"; sleep 2; } | socat - "UNIX-CONNECT:$MON" >/dev/null; }

screenshot() {
  monitor "screendump $OUT/$1.ppm"
  convert "$OUT/$1.ppm" "$OUT/$1.png" 2>/dev/null && rm -f "$OUT/$1.ppm"
}

type_line() {
  local key
  for key in $(echo "$1" | grep -o .) ret; do
    monitor "sendkey $key"
  done
}

wait_for() {
  local pattern=$1 seconds=$2 n=0
  while (( seconds-- > 0 )); do
    grep -q "$pattern" "$OUT/boot.log" 2>/dev/null && return 0
    kill -0 "$QEMU_PID" 2>/dev/null || return 1
    if (( ++n % 60 == 0 )); then
      echo "-- waiting for $pattern, +$((n / 60))m: $(tail -n 1 "$OUT/boot.log" | tr -d '\r' | cut -c1-160)"
      screenshot boot-latest || true
    fi
    sleep 1
  done
  return 1
}

echo "== First boot"
wait_for INTENT_OS_FIRSTBOOT $((600 * slow)) || { screenshot boot-latest || true; fail "no first-boot prompt"; }
sleep 5
type_line "$PIN"
sleep 2
type_line "$PIN"
sleep 2
type_line ""

echo "== Waiting for Intent"
booted=0
wait_for INTENT_OS_BOOT_OK $((600 * slow)) && booted=1
screenshot locked || true
type_line "$PIN"
sleep $((15 * slow))
screenshot unlocked || true
monitor "quit" || kill "$QEMU_PID" 2>/dev/null || true
wait "$QEMU_PID" 2>/dev/null || true
trap - EXIT

(( booted )) || fail "Intent window never appeared (no INTENT_OS_BOOT_OK on serial)"
result "PASS: first boot PIN set, Intent window visible"
