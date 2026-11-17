#!/bin/bash
# Runs inside a privileged archlinux:base-devel container with the repo at /src.
#   packages: build Intent OS pacman packages into out/repo
#   iso:      build the installer ISO (netinstall) into out/iso
#   all:      both
# Env: ARCHIVE_DATE (YYYY/MM/DD), BUILD_ID, INTENT_OS_SIGNING_KEY (optional,
# ASCII-armored secret key), HOST_UID (chown output for the host user).
set -euo pipefail

SRC=/src
OUT=$SRC/out
WORK=/tmp/intent-os
PACKAGES=(intent-appimage intent-os-base intent-os-session intent-os-update intent-os-hw-macbookair6)

: "${ARCHIVE_DATE:?set ARCHIVE_DATE, for example 2026/11/15}"
: "${BUILD_ID:?set BUILD_ID}"
[[ $ARCHIVE_DATE =~ ^[0-9]{4}/[0-9]{2}/[0-9]{2}$ ]] || { echo "bad ARCHIVE_DATE" >&2; exit 1; }

log() { printf '\n==> %s\n' "$*"; }

prepare() {
  log "Preparing build container"
  pacman-key --init >/dev/null
  pacman-key --populate archlinux >/dev/null
  pacman -Syu --noconfirm --needed archiso git grub erofs-utils mtools dosfstools >/dev/null
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
      sudo -u builder env PKGDEST="$OUT/repo" SRCDEST="$WORK/src" \
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
  pacman -S --noconfirm --needed linux linux-headers broadcom-wl-dkms linux-firmware-intel >/dev/null
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
  (cd /usr/lib/firmware && find . \( -name 'iwlwifi-*' -o -path './intel/iwlwifi*' \) -print0 |
    tar --null -cf - -T - | tar -xf - -C "$dir/root" --one-top-level=usr/lib/firmware)
  cat > "$dir/PKGBUILD" <<PKG
pkgname=intent-os-live
pkgver=1
pkgrel=1
pkgdesc="Intent OS live installer Wi-Fi: prebuilt wl driver and iwlwifi firmware"
arch=(x86_64)
license=(custom)
depends=("linux=$linux_ver")
options=(!strip !debug)
package() { cp -a "\$startdir/root/." "\$pkgdir/"; }
PKG
  chown -R builder "$dir" "$WORK/live-repo"
  (cd "$dir" && sudo -u builder env PKGDEST="$WORK/live-repo" makepkg -fd --noconfirm >/dev/null)
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
  # The netinstall image must stay small; fail here, not at publish.
  local iso size limit=$((600 * 1024 * 1024))
  iso=$(ls "$OUT"/iso/*.iso)
  size=$(stat -c %s "$iso")
  log "ISO size: $((size / 1024 / 1024)) MiB (limit 600 MiB)"
  if (( size > limit )); then
    echo "error: ISO is $((size / 1024 / 1024)) MiB; the netinstall image must stay under 600 MiB" >&2
    exit 1
  fi
}

prepare
case ${1:-all} in
  packages) build_packages ;;
  iso) build_iso ;;
  all) build_packages; build_iso ;;
  *) echo "usage: $0 packages|iso|all" >&2; exit 2 ;;
esac
[[ -n ${HOST_UID:-} ]] && chown -R "$HOST_UID" "$OUT"
log "Done: $OUT"
