#!/bin/bash
# Runs inside a privileged container with the repo at /src: archlinux:base-devel
# on x86_64, an Arch Linux ARM image on aarch64 (see the Makefile).
#   packages: build Intent OS pacman packages into out/repo
#   iso:      build the installer ISO (netinstall) into out/iso   (x86_64)
#   vm:       build a ready-to-boot VM disk image into out/vm     (aarch64)
#   all:      packages plus the image for this architecture
# Env: ARCHIVE_DATE (YYYY/MM/DD), BUILD_ID, INTENT_OS_SIGNING_KEY (optional,
# ASCII-armored secret key), HOST_UID (chown output for the host user).
set -euo pipefail

SRC=/src
OUT=$SRC/out
WORK=/tmp/intent-os
ARCH=$(uname -m)
PACKAGES=(intent-appimage intent-os-base intent-os-session intent-os-update)
[[ $ARCH == x86_64 ]] && PACKAGES+=(intent-os-hw-macbookair6)

: "${ARCHIVE_DATE:?set ARCHIVE_DATE, for example 2026/11/15}"
: "${BUILD_ID:?set BUILD_ID}"
[[ $ARCHIVE_DATE =~ ^[0-9]{4}/[0-9]{2}/[0-9]{2}$ ]] || { echo "bad ARCHIVE_DATE" >&2; exit 1; }

log() { printf '\n==> %s\n' "$*"; }

prepare() {
  log "Preparing build container"
  pacman-key --init >/dev/null
  if [[ $ARCH == aarch64 ]]; then
    pacman-key --populate archlinuxarm >/dev/null
    # The imported rootfs keeps CheckSpace, which fails on overlay mounts.
    sed -i 's/^CheckSpace/#CheckSpace/' /etc/pacman.conf
    pacman -Syu --noconfirm --needed base-devel git arch-install-scripts btrfs-progs \
      dosfstools gptfdisk qemu-img >/dev/null
  else
    pacman-key --populate archlinux >/dev/null
    pacman -Syu --noconfirm --needed archiso git grub erofs-utils mtools dosfstools >/dev/null
  fi
  id builder >/dev/null 2>&1 || useradd -m builder
  mkdir -p "$OUT" "$WORK"
  SIGN_ARGS=() REPO_SIGN_ARGS=() KEY_ID=""
  if [[ -n ${INTENT_OS_SIGNING_KEY:-} ]]; then
    log "Importing signing key"
    for home in /root /home/builder; do
      install -d -m700 -o "$(stat -c %u "$home")" "$home/.gnupg"
    done
    printf '%s\n' "$INTENT_OS_SIGNING_KEY" | gpg --batch --import
    printf '%s\n' "$INTENT_OS_SIGNING_KEY" | sudo -u builder gpg --batch --import
    KEY_ID=$(gpg --batch --list-secret-keys --with-colons | awk -F: '$1 == "fpr" {print $10; exit}')
    SIGN_ARGS=(--sign --key "$KEY_ID")
    REPO_SIGN_ARGS=(--sign --key "$KEY_ID")
    mkdir -p "$OUT/keyring"
    gpg --batch --armor --export "$KEY_ID" > "$OUT/keyring/intent-os.gpg"
    echo "$KEY_ID:4:" > "$OUT/keyring/intent-os-trusted"
  fi
}

build_packages() {
  log "Building packages"
  rm -rf "$OUT/repo" "$WORK/pkgbuild"
  mkdir -p "$OUT/repo" "$WORK/pkgbuild" "$WORK/src"
  chown builder "$OUT/repo" "$WORK/src"
  local p
  for p in "${PACKAGES[@]}"; do
    cp -r "$SRC/packages/$p" "$WORK/pkgbuild/$p"
    chown -R builder "$WORK/pkgbuild/$p"
    (cd "$WORK/pkgbuild/$p" &&
      sudo -u builder env PKGDEST="$OUT/repo" SRCDEST="$WORK/src" PKGEXT=.pkg.tar.zst \
        makepkg -fd --noconfirm "${SIGN_ARGS[@]}")
  done
  repo-add -q "${REPO_SIGN_ARGS[@]}" "$OUT/repo/intent-os.db.tar.gz" "$OUT"/repo/*.pkg.tar.zst
  # Release assets cannot be symlinks.
  local f
  for f in intent-os.db intent-os.files intent-os.db.sig intent-os.files.sig; do
    [[ -L $OUT/repo/$f ]] && cp --remove-destination "$(readlink -f "$OUT/repo/$f")" "$OUT/repo/$f"
  done
  local intent_version
  intent_version=$(sed -n 's/^pkgver=//p' "$SRC/packages/intent-appimage/PKGBUILD")
  printf 'ARCHIVE_DATE=%s\nBUILD_ID=%s\nINTENT_VERSION=%s\n' \
    "$ARCHIVE_DATE" "$BUILD_ID" "$intent_version" > "$OUT/channel.env"
}

write_mirrorlist() {
  # shellcheck disable=SC2016 # pacman expands $repo and $arch
  printf 'Server = https://archive.archlinux.org/repos/%s/$repo/os/$arch\n' "$ARCHIVE_DATE" > "$1"
}

# intent-os-live: the MacBook Air wl driver built once for the live kernel,
# plus Intel iwlwifi firmware only, so the USB stick needs no compiler,
# headers or full firmware packages.
build_live_package() {
  log "Building the live Wi-Fi package"
  pacman -S --noconfirm --needed linux linux-headers broadcom-wl-dkms \
    linux-firmware-intel linux-firmware-atheros linux-firmware-mediatek >/dev/null
  local linux_ver kdir wl dir=$WORK/live-pkg
  linux_ver=$(pacman -Q linux | awk '{print $2}')
  kdir=$(find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d -exec test -e '{}/updates/dkms' ';' -print | head -n1)
  wl=$(find "$kdir/updates/dkms" -name 'wl.ko*' | head -n1)
  [[ -n $wl ]] || { echo "error: dkms did not build wl for $kdir" >&2; exit 1; }
  rm -rf "$dir" "$WORK/live-repo"
  mkdir -p "$dir/root" "$WORK/live-repo"
  install -Dm644 "$wl" "$dir/root${wl}"
  local conf
  for conf in /usr/lib/modprobe.d/broadcom-wl*.conf; do
    install -Dm644 "$conf" "$dir/root$conf"
  done
  mkdir -p "$dir/root/usr/lib/firmware"
  # Wi-Fi files only: Intel iwlwifi, Qualcomm Atheros ath*k, MediaTek mt7x
  # (no Bluetooth, GPU or SoC firmware from these packages).
  (cd /usr/lib/firmware && find . \( -type f -o -type l \) \( \
      -name 'iwlwifi-*' \
      -o -path './ath9k_htc/*' -o -path './ath10k/*' -o -path './ath11k/*' \
      -o -path './ath12k/*' -o -path './ath6k/*' -o -name 'htc_*.fw' \
      -o \( \( -name 'mt7*' -o -name 'WIFI_*' \) ! -name '*BT*' \) \) \
      -exec cp -a --parents {} "$dir/root/usr/lib/firmware" \;)
  cat > "$dir/PKGBUILD" <<PKG
pkgname=intent-os-live
pkgver=1
pkgrel=1
pkgdesc="Intent OS live installer Wi-Fi: prebuilt wl driver and Wi-Fi firmware"
arch=(x86_64)
license=(custom)
depends=("linux=$linux_ver")
options=(!strip !debug)
package() { cp -a "\$startdir/root/." "\$pkgdir/"; }
PKG
  # iwlwifi ships many API versions per chip; the driver loads the newest it
  # supports, so the two newest per chip are enough.
  local f
  while read -r f; do rm -f "$dir/root/usr/lib/firmware/$f"; done < <(
    cd "$dir/root/usr/lib/firmware" &&
      find . -name 'iwlwifi-*.ucode*' | sed 's|^\./||' |
      awk '{ n = $0; sub(/\.ucode.*$/, "", n); v = n; sub(/^.*-/, "", v); gsub(/[^0-9]/, "", v);
             p = n; sub(/-[^-]*$/, "", p); print p "\t" (v == "" ? 0 : v) "\t" $0 }' |
      sort -t $'\t' -k1,1 -k2,2nr |
      awk -F '\t' '{ if (++seen[$1] > 2) print $3 }')
  find "$dir/root/usr/lib/firmware" -xtype l -delete
  chown -R builder "$dir" "$WORK/live-repo"
  (cd "$dir" && sudo -u builder env PKGDEST="$WORK/live-repo" PKGEXT=.pkg.tar.zst makepkg -fd --noconfirm >/dev/null)
  repo-add -q "$WORK/live-repo/intent-os-live.db.tar.gz" "$WORK"/live-repo/*.pkg.tar.zst
}

build_iso() {
  log "Building installer ISO"
  local profile=$WORK/profile
  rm -rf "$profile" "$WORK/archiso"
  cp -r /usr/share/archiso/configs/baseline "$profile"
  build_live_package

  # Our own package list and services; drop baseline's cloud and VM tooling.
  cp "$SRC/iso/packages.x86_64" "$profile/packages.x86_64"
  rm -rf "$profile/airootfs/etc/systemd/system/"*.wants \
    "$profile/airootfs/etc/systemd/system/systemd-networkd-wait-online.service.d" \
    "$profile/airootfs/etc/systemd/network" "$profile/airootfs/etc/systemd/networkd.conf.d" \
    "$profile/airootfs/etc/systemd/resolved.conf.d" "$profile/airootfs/etc/ssh"
  cp -a "$SRC/iso/airootfs/." "$profile/airootfs/"
  mkdir -p "$profile/airootfs/etc/systemd/system/multi-user.target.wants"
  ln -sf /usr/lib/systemd/system/NetworkManager.service \
    "$profile/airootfs/etc/systemd/system/multi-user.target.wants/NetworkManager.service"
  # The installer needs no docs, translations or headers on the stick.
  sed -i '/^\[options\]/a NoExtract = usr/share/locale/* usr/share/man/* usr/share/doc/* usr/share/info/* usr/share/gtk-doc/* usr/share/gir-1.0/* usr/include/* usr/share/i18n/*\nNoExtract = !usr/share/locale/locale.alias' "$profile/pacman.conf"
  cat >> "$profile/pacman.conf" <<CONF

[intent-os-live]
SigLevel = Optional TrustAll
Server = file://$WORK/live-repo
CONF

  # Serial console for the QEMU boot test. Harmless on hardware.
  find "$profile/efiboot" "$profile/grub" "$profile/syslinux" -type f \
    \( -name '*.conf' -o -name '*.cfg' \) \
    -exec sed -i 's/archisosearchuuid=%ARCHISO_UUID%/& console=tty0 console=ttyS0,115200/' {} + 2>/dev/null || true

  sed -i -E \
    -e 's/^iso_name=.*/iso_name="intent-os"/' \
    -e 's/^iso_label=.*/iso_label="INTENT_OS"/' \
    -e 's|^iso_publisher=.*|iso_publisher="Intent HQ <https://intentapp.dev>"|' \
    -e 's/^iso_application=.*/iso_application="Intent OS installer"/' \
    -e "s/^iso_version=.*/iso_version=\"$BUILD_ID\"/" \
    -e 's|^file_permissions=\(|&\n  ["/usr/local/bin/intent-os-install"]="0:0:755"|' \
    "$profile/profiledef.sh"

  local etc=$profile/airootfs/etc/intent-os
  mkdir -p "$etc"
  write_mirrorlist "$etc/mirrorlist"
  # The installer downloads from the pinned Arch snapshot and the signed
  # intent-os repo; the ISO carries no packages of its own.
  local intent_siglevel="Optional TrustAll"
  if [[ -d $OUT/keyring ]]; then
    cp "$OUT/keyring/intent-os.gpg" "$OUT/keyring/intent-os-trusted" "$etc/"
    intent_siglevel="Required DatabaseRequired"
  fi
  cat > "$etc/pacman-install.conf" <<CONF
[options]
Architecture = x86_64
SigLevel = Required DatabaseOptional
ParallelDownloads = 5

[intent-os]
SigLevel = $intent_siglevel
Server = https://github.com/intent-hq/intent-os/releases/download/repo-\$arch

[core]
Include = /etc/intent-os/mirrorlist

[extra]
Include = /etc/intent-os/mirrorlist
CONF

  rm -rf "$OUT/iso"
  mkarchiso -v -w "$WORK/archiso" -o "$OUT/iso" "$profile"
  (cd "$OUT/iso" && sha256sum ./*.iso > SHA256SUMS)
  log "Largest parts of the live system"
  du -x -m --max-depth=5 "$WORK/archiso/x86_64/airootfs/usr" 2>/dev/null | sort -n | tail -n 25
  # The netinstall image must stay small; fail here, not at publish.
  local iso size limit=$((560 * 1024 * 1024))
  iso=$(ls "$OUT"/iso/*.iso)
  size=$(stat -c %s "$iso")
  log "ISO size: $((size / 1024 / 1024)) MiB (limit 560 MiB)"
  if (( size > limit )); then
    echo "error: ISO is $((size / 1024 / 1024)) MiB; the netinstall image must stay under 560 MiB" >&2
    exit 1
  fi
}

# arm64 VM image: install with the normal installer onto two loop devices
# (ESP and btrfs root) inside a sparse raw disk, then compress to qcow2. The
# device asks for the PIN on first boot.
build_vm_image() {
  log "Building the $ARCH VM disk image"
  local img=$WORK/intent-os.raw esp root s1 n1 s2 n2
  rm -rf "$OUT/vm" && mkdir -p "$OUT/vm"
  rm -f "$img" && truncate -s 16G "$img"
  sgdisk -n1:0:+512M -t1:ef00 -c1:EFI -n2:0:0 -t2:8300 -c2:intent-os "$img" >/dev/null
  read -r s1 n1 < <(partx -g -o START,SECTORS -n 1 "$img")
  read -r s2 n2 < <(partx -g -o START,SECTORS -n 2 "$img")
  esp=$(losetup -f --show -o $((s1 * 512)) --sizelimit $((n1 * 512)) "$img")
  root=$(losetup -f --show -o $((s2 * 512)) --sizelimit $((n2 * 512)) "$img")
  # shellcheck disable=SC2064
  trap "umount -R /mnt 2>/dev/null; losetup -d $esp $root 2>/dev/null" EXIT

  mkdir -p /etc/intent-os
  local intent_siglevel="Optional TrustAll"
  if [[ -d $OUT/keyring ]]; then
    cp "$OUT/keyring/intent-os.gpg" "$OUT/keyring/intent-os-trusted" /etc/intent-os/
    intent_siglevel="Required DatabaseRequired"
  fi
  cat > /etc/intent-os/pacman-install.conf <<CONF
[options]
Architecture = $ARCH
SigLevel = Required DatabaseOptional
ParallelDownloads = 5

[intent-os]
SigLevel = $intent_siglevel
Server = https://github.com/intent-hq/intent-os/releases/download/repo-\$arch

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist

[alarm]
Include = /etc/pacman.d/mirrorlist
CONF
  cat > "$WORK/vm.conf" <<CONF
IMAGE=1
FIRSTBOOT=1
ESP_DEV=$esp
ROOT_DEV=$root
TIMEZONE=UTC
REPO=file://$OUT/repo
CONSOLE=console=ttyAMA0,115200 console=tty0
CONF
  INTENT_OS_INSTALL_CONFIG=$WORK/vm.conf bash "$SRC/iso/airootfs/usr/local/bin/intent-os-install"
  losetup -d "$esp" "$root"
  trap - EXIT

  local qcow=$OUT/vm/intent-os-$BUILD_ID-arm64.qcow2 size limit=$((1900 * 1024 * 1024))
  qemu-img convert -c -O qcow2 -o compression_type=zstd "$img" "$qcow"
  rm -f "$img"
  (cd "$OUT/vm" && sha256sum ./*.qcow2 > SHA256SUMS)
  size=$(stat -c %s "$qcow")
  log "VM image size: $((size / 1024 / 1024)) MiB (limit 1900 MiB)"
  (( size <= limit )) || { echo "error: VM image is over GitHub's 2 GiB asset limit" >&2; exit 1; }
}

prepare
case ${1:-all} in
  packages) build_packages ;;
  iso) build_iso ;;
  vm) build_vm_image ;;
  all)
    build_packages
    if [[ $ARCH == aarch64 ]]; then build_vm_image; else build_iso; fi ;;
  *) echo "usage: $0 packages|iso|vm|all" >&2; exit 2 ;;
esac
[[ -n ${HOST_UID:-} ]] && chown -R "$HOST_UID" "$OUT"
log "Done: $OUT"
