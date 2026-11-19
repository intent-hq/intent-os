#!/bin/bash
# Boot-to-Intent test in QEMU/KVM with UEFI:
#   1. Boot the ISO and run the unattended installer onto a blank disk.
#   2. Boot the installed disk; wait until Intent's window is on screen.
#   3. Take a screenshot of the lock screen, type the PIN, take another.
#   4. Open a second Intent window (Ctrl+Shift+N): it must get workspace 2.
#      Super+Left/Right must move between the two windows.
# Artifacts: install.log, boot.log, locked.png, unlocked.png, windows.png,
# result.txt, and
# install-latest.png / boot-latest.png (last per-minute screenshot).
# Needs: qemu-system-x86_64, OVMF, socat, /dev/kvm.
set -euo pipefail

ISO=${1:?usage: tests/smoke.sh <iso> [out-dir]}
OUT=${2:-out/smoke}
PIN=2468
# Not UTC, so a time zone the installer drops shows up.
TZ_UNDER_TEST=America/Los_Angeles
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

find_first() {
  local f
  for f in "$@"; do [[ -f $f ]] && { echo "$f"; return; }; done
  return 1
}
# x86_64 or aarch64, from the ISO name (intent-os-<build>-<arch>.iso).
ARCH=x86_64
[[ $ISO == *aarch64.iso ]] && ARCH=aarch64

result() { echo "$1" | tee "$OUT/result.txt"; }
fail() { result "FAIL: $1"; exit 1; }

rm -f "$OUT/disk.qcow2"
qemu-img create -q -f qcow2 "$OUT/disk.qcow2" 32G
# Serve the packages under test; the VM reaches the host at 10.0.2.2.
REPO_DIR=$(cd "$(dirname "$ISO")/../repo" && pwd)
python3 -m http.server 8080 --bind 127.0.0.1 --directory "$REPO_DIR" >"$OUT/repo-http.log" 2>&1 &
HTTP_PID=$!
trap 'kill "$HTTP_PID" 2>/dev/null || true' EXIT

printf 'DISK=/dev/vda\nPIN=%s\nTIMEZONE=%s\nAFTER=poweroff\nREPO=http://10.0.2.2:8080\n' "$PIN" "$TZ_UNDER_TEST" > "$OUT/auto.conf"

# slow scales waits when there is no KVM (aarch64 CI runners may lack it).
slow=1
if [[ $ARCH == x86_64 ]]; then
  # Force the MacBook Air package so the Broadcom DKMS build is tested too.
  echo "HW=intent-os-hw-macbookair6" >> "$OUT/auto.conf"
  QEMU=qemu-system-x86_64
  OVMF_CODE=$(find_first /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/x64/OVMF_CODE.4m.fd)
  OVMF_VARS=$(find_first /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/edk2/x64/OVMF_VARS.4m.fd)
  cp "$OVMF_VARS" "$OUT/vars.fd"
  # shellcheck disable=SC2054
  common=(
    -enable-kvm -machine q35 -cpu host -smp 2 -m 4096
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
    -drive "if=pflash,format=raw,file=$OUT/vars.fd"
    -vga virtio
  )
  cdrom=(-cdrom "$ISO")
else
  QEMU=qemu-system-aarch64
  FIRMWARE=$(find_first /usr/share/qemu-efi-aarch64/QEMU_EFI.fd /usr/share/edk2/aarch64/QEMU_EFI.fd /usr/share/AAVMF/AAVMF_CODE.fd)
  accel=(-accel tcg -cpu max)
  slow=3
  if [[ -w /dev/kvm ]]; then accel=(-accel kvm -cpu host); slow=1; fi
  # shellcheck disable=SC2054
  common=(
    -M virt "${accel[@]}" -smp 4 -m 4096 -bios "$FIRMWARE"
    -device virtio-gpu-pci -device qemu-xhci -device usb-kbd -device usb-tablet
  )
  # shellcheck disable=SC2054
  cdrom=(-drive "file=$ISO,media=cdrom,if=none,id=cd0,readonly=on"
    -device virtio-scsi-pci -device scsi-cd,drive=cd0)
fi
# shellcheck disable=SC2054
common+=(
  -drive "file=$OUT/disk.qcow2,if=virtio,format=qcow2"
  -nic user,model=virtio-net-pci -display none
)

# Print serial progress and save a screenshot every minute, so a hang is
# visible in the job log and the artifacts instead of only at the timeout.
watch_vm() {
  local pid=$1 log=$2 mon=$3 name=$4 n=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 60
    n=$((n + 1))
    echo "-- $name +${n}m: $(tail -n 2 "$log" 2>/dev/null | tr -d '\r' | tr '\n' ' ' | cut -c1-200)"
    { echo "screendump $OUT/$name-latest.ppm"; sleep 2; } | socat - "UNIX-CONNECT:$mon" >/dev/null 2>&1 || true
  done
}

echo "== Installing"
IMON=$OUT/install-monitor.sock
rm -f "$IMON"
"$QEMU" "${common[@]}" "${cdrom[@]}" \
  -fw_cfg "name=opt/intent-os/install,file=$OUT/auto.conf" \
  -serial "file:$OUT/install.log" \
  -monitor "unix:$IMON,server,nowait" &
INSTALL_PID=$!
watch_vm "$INSTALL_PID" "$OUT/install.log" "$IMON" install &
WATCH_PID=$!
( sleep $((1800 * slow)); kill "$INSTALL_PID" 2>/dev/null ) &
TIMER_PID=$!
wait "$INSTALL_PID" || true
kill "$TIMER_PID" "$WATCH_PID" 2>/dev/null || true
grep -q INTENT_OS_INSTALL_OK "$OUT/install.log" || fail "installer did not report success (see install-latest.png, install.log)"

echo "== Booting the installed system"
MON=$OUT/monitor.sock
rm -f "$MON"
# opt/intent-os/test turns on intent-os-test-report, which prints the window
# placement (INTENT_OS_WINDOWS focused=<ws> intent=<ws,...>;) to the serial log.
"$QEMU" "${common[@]}" \
  -fw_cfg "name=opt/intent-os/test,string=1" \
  -serial "file:$OUT/boot.log" \
  -monitor "unix:$MON,server,nowait" &
QEMU_PID=$!
watch_vm "$QEMU_PID" "$OUT/boot.log" "$MON" boot &
WATCH_PID=$!
trap 'kill "$QEMU_PID" "$WATCH_PID" "$HTTP_PID" 2>/dev/null || true' EXIT

# QEMU's PPM screendump works without PNG support; convert for the artifacts.
screenshot() {
  monitor "screendump $OUT/$1.ppm"
  convert "$OUT/$1.ppm" "$OUT/$1.png" 2>/dev/null && rm -f "$OUT/$1.ppm"
}

# Keep the connection open briefly: QEMU drops a command whose client hangs up at once.
monitor() { { echo "$1"; sleep 2; } | socat - "UNIX-CONNECT:$MON" >/dev/null; }

# wait_for <pattern> <seconds> [byte offset]: only log text after the offset counts.
wait_for() {
  local pattern=$1 seconds=$2 from=${3:-0}
  while (( seconds-- > 0 )); do
    # Not a pipe: with pipefail, grep -q exiting early can fail tail with SIGPIPE.
    grep -q "$pattern" < <(tail -c "+$((from + 1))" "$OUT/boot.log" 2>/dev/null) && return 0
    kill -0 "$QEMU_PID" 2>/dev/null || return 1
    sleep 1
  done
  return 1
}

# Intent loads behind the lock, so boot-ok can arrive before the PIN.
booted=0
wait_for INTENT_OS_BOOT_OK $((480 * slow)) && booted=1
screenshot locked

for key in $(echo "$PIN" | grep -o .) ret; do
  monitor "sendkey $key"
  sleep 0.3
done
(( booted )) || { wait_for INTENT_OS_BOOT_OK $((240 * slow)) && booted=1; }
sleep $((15 * slow))
screenshot unlocked

log_size() { stat -c %s "$OUT/boot.log"; }
# press <qemu key> <expected INTENT_OS_WINDOWS state> <seconds>
press() {
  local from
  from=$(log_size)
  monitor "sendkey $1"
  wait_for "INTENT_OS_WINDOWS $2;" "$3" "$from"
}
windows_error=""
if (( booted )); then
  echo "== Two Intent windows"
  if ! wait_for 'INTENT_OS_WINDOWS focused=1 intent=1;' $((60 * slow)); then
    windows_error="first Intent window not reported on workspace 1"
  # Retry once: Intent can still be loading its first window's page.
  elif ! press ctrl-shift-n 'focused=2 intent=1,2' $((90 * slow)) &&
       ! press ctrl-shift-n 'focused=2 intent=1,2' $((90 * slow)); then
    windows_error="Ctrl+Shift+N did not put a second Intent window on workspace 2"
  elif ! press meta_l-left 'focused=1 intent=1,2' $((30 * slow)); then
    windows_error="Super+Left did not go to workspace 1"
  elif ! press meta_l-right 'focused=2 intent=1,2' $((30 * slow)); then
    windows_error="Super+Right did not go to workspace 2"
  fi
  sleep $((5 * slow))
  screenshot windows
  echo "-- windows: $(grep -ao 'INTENT_OS_WINDOWS [^;]*;' "$OUT/boot.log" | tr '\n' ' ')"
fi
# Quit QEMU directly: Intent OS maps the power button to suspend, so an ACPI
# power-down would leave the VM asleep and the test waiting forever.
monitor "quit" || kill "$QEMU_PID" 2>/dev/null || true
wait "$QEMU_PID" 2>/dev/null || true
trap - EXIT
kill "$HTTP_PID" 2>/dev/null || true
for f in "$OUT"/*-latest.ppm; do
  [[ -f $f ]] && convert "$f" "${f%.ppm}.png" 2>/dev/null && rm -f "$f"
done
ls -l "$OUT"/*.png 2>/dev/null || echo "warning: no screenshots were saved"

(( booted )) || fail "Intent window never appeared (no INTENT_OS_BOOT_OK on serial)"
grep -q "INTENT_OS_BOOT_OK tz=/usr/share/zoneinfo/$TZ_UNDER_TEST" "$OUT/boot.log" ||
  fail "time zone not set to $TZ_UNDER_TEST ($(grep -ao 'INTENT_OS_BOOT_OK tz=[^ ]*' "$OUT/boot.log" | head -n1))"
[[ -z $windows_error ]] || fail "$windows_error (see windows.png, boot.log)"
result "PASS: installed, booted, Intent window visible, time zone kept, two windows on workspaces 1 and 2, Super+Left/Right switch"
