#!/bin/bash
# Boot-to-Intent test in QEMU/KVM with UEFI:
#   1. Boot the ISO and run the unattended installer onto a blank disk.
#   2. Boot the installed disk; wait until Intent's window is on screen.
#   3. Take a screenshot of the lock screen, type the PIN, take another.
# Artifacts: install.log, boot.log, locked.png, unlocked.png, result.txt.
# Needs: qemu-system-x86_64, OVMF, socat, /dev/kvm.
set -euo pipefail

ISO=${1:?usage: tests/smoke.sh <iso> [out-dir]}
OUT=${2:-out/smoke}
PIN=2468
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

find_first() {
  local f
  for f in "$@"; do [[ -f $f ]] && { echo "$f"; return; }; done
  return 1
}
OVMF_CODE=$(find_first /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/x64/OVMF_CODE.4m.fd)
OVMF_VARS=$(find_first /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/edk2/x64/OVMF_VARS.4m.fd)

result() { echo "$1" | tee "$OUT/result.txt"; }
fail() { result "FAIL: $1"; exit 1; }

cp "$OVMF_VARS" "$OUT/vars.fd"
rm -f "$OUT/disk.qcow2"
qemu-img create -q -f qcow2 "$OUT/disk.qcow2" 32G
# Force the MacBook Air package so the Broadcom DKMS build is tested too.
printf 'DISK=/dev/vda\nPIN=%s\nTIMEZONE=UTC\nAFTER=poweroff\nHW=intent-os-hw-macbookair6\n' "$PIN" > "$OUT/auto.conf"

# shellcheck disable=SC2054
common=(
  -enable-kvm -machine q35 -cpu host -smp 2 -m 4096
  -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
  -drive "if=pflash,format=raw,file=$OUT/vars.fd"
  -drive "file=$OUT/disk.qcow2,if=virtio,format=qcow2"
  -nic user,model=virtio-net-pci
  -vga virtio -display none
)

echo "== Installing"
timeout 45m qemu-system-x86_64 "${common[@]}" \
  -cdrom "$ISO" \
  -fw_cfg "name=opt/intent-os/install,file=$OUT/auto.conf" \
  -serial "file:$OUT/install.log" || fail "installer VM did not finish"
grep -q INTENT_OS_INSTALL_OK "$OUT/install.log" || fail "installer did not report success"

echo "== Booting the installed system"
MON=$OUT/monitor.sock
rm -f "$MON"
qemu-system-x86_64 "${common[@]}" \
  -serial "file:$OUT/boot.log" \
  -monitor "unix:$MON,server,nowait" &
QEMU_PID=$!
trap 'kill "$QEMU_PID" 2>/dev/null || true' EXIT

monitor() { echo "$1" | socat - "UNIX-CONNECT:$MON" >/dev/null; }

wait_for() {
  local pattern=$1 seconds=$2
  while (( seconds-- > 0 )); do
    grep -q "$pattern" "$OUT/boot.log" 2>/dev/null && return 0
    kill -0 "$QEMU_PID" 2>/dev/null || return 1
    sleep 1
  done
  return 1
}

# Intent loads behind the lock, so boot-ok can arrive before the PIN.
booted=0
wait_for INTENT_OS_BOOT_OK 480 && booted=1
monitor "screendump -f png $OUT/locked.png"

for key in $(echo "$PIN" | grep -o .) ret; do
  monitor "sendkey $key"
  sleep 0.3
done
(( booted )) || { wait_for INTENT_OS_BOOT_OK 240 && booted=1; }
sleep 15
monitor "screendump -f png $OUT/unlocked.png"
monitor "system_powerdown"
wait "$QEMU_PID" 2>/dev/null || true
trap - EXIT

(( booted )) || fail "Intent window never appeared (no INTENT_OS_BOOT_OK on serial)"
result "PASS: installed, booted, Intent window visible"
