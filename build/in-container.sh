#!/bin/bash
# Runs inside a privileged archlinux:base-devel container with the repo at /src.
#   packages: build Intent OS pacman packages into out/repo
#   iso:      build the offline installer ISO into out/iso
#   all:      both
# Env: ARCHIVE_DATE (YYYY/MM/DD), BUILD_ID, INTENT_OS_SIGNING_KEY (optional,
# ASCII-armored secret key), HOST_UID (chown output for the host user).
set -euo pipefail

SRC=/src
OUT=$SRC/out
WORK=/tmp/intent-os
PACKAGES=(intent-appimage intent-os-base intent-os-session intent-os-update intent-os-hw-macbookair6)
INSTALL_SET=(intent-os-base intent-os-session intent-os-update intent-os-hw-macbookair6)

: "${ARCHIVE_DATE:?set ARCHIVE_DATE, for example 2026/11/15}"
: "${BUILD_ID:?set BUILD_ID}"
[[ $ARCHIVE_DATE =~ ^[0-9]{4}/[0-9]{2}/[0-9]{2}$ ]] || { echo "bad ARCHIVE_DATE" >&2; exit 1; }

log() { printf '\n==> %s\n' "$*"; }

prepare() {
  log "Preparing build container"
  pacman-key --init >/dev/null
  pacman-key --populate archlinux >/dev/null
  pacman -Syu --noconfirm --needed archiso git >/dev/null
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
    # The offline repo download verifies the signed intent-os repo.
    pacman-key --add "$OUT/keyring/intent-os.gpg" >/dev/null
    pacman-key --lsign-key "$KEY_ID" >/dev/null
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

offline_repo() {
  local repo=$1 conf=$WORK/pinned.conf
  log "Downloading the pinned package set ($ARCHIVE_DATE)"
  write_mirrorlist "$WORK/mirrorlist"
  cat > "$conf" <<CONF
[options]
Architecture = x86_64
SigLevel = Required DatabaseOptional
ParallelDownloads = 8

[core]
Include = $WORK/mirrorlist

[extra]
Include = $WORK/mirrorlist

[intent-os]
SigLevel = Optional TrustAll
Server = file://$OUT/repo
CONF
  rm -rf "$WORK/db" && mkdir -p "$WORK/db" "$repo"
  pacman --config "$conf" --dbpath "$WORK/db" -Sy >/dev/null
  pacman --config "$conf" --dbpath "$WORK/db" --cachedir "$repo" -Sw --noconfirm "${INSTALL_SET[@]}"
  rm -f "$repo"/*.sig
  repo-add -q "$repo/intent-os-offline.db.tar.gz" "$repo"/*.pkg.tar.zst
}

build_iso() {
  log "Building installer ISO"
  local profile=$WORK/profile
  rm -rf "$profile" "$WORK/archiso"
  cp -r /usr/share/archiso/configs/releng "$profile"

  # Same reduced firmware set as intent-os-base, to keep the ISO under 2 GiB.
  sed -i '/^linux-firmware/d' "$profile/packages.x86_64"
  grep -v '^#' "$SRC/iso/packages.x86_64" >> "$profile/packages.x86_64"
  cp -a "$SRC/iso/airootfs/." "$profile/airootfs/"

  # NetworkManager replaces iwd and systemd-networkd in the live system.
  find "$profile/airootfs/etc/systemd/system" \
    \( -name 'iwd.service' -o -name 'systemd-networkd*' \) ! -type d -delete
  ln -sf /usr/lib/systemd/system/NetworkManager.service \
    "$profile/airootfs/etc/systemd/system/multi-user.target.wants/NetworkManager.service"

  # Serial console for the QEMU boot test. Harmless on hardware.
  find "$profile/efiboot" "$profile/grub" "$profile/syslinux" -type f \
    \( -name '*.conf' -o -name '*.cfg' \) \
    -exec sed -i 's/archisosearchuuid=%ARCHISO_UUID%/& console=tty0 console=ttyS0,115200/' {} + 2>/dev/null

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
  cat > "$etc/pacman-offline.conf" <<'CONF'
[options]
Architecture = x86_64
SigLevel = Never
ParallelDownloads = 5

[intent-os-offline]
Server = file:///opt/intent-os/repo
CONF
  if [[ -d $OUT/keyring ]]; then
    cp "$OUT/keyring/intent-os.gpg" "$OUT/keyring/intent-os-trusted" "$etc/"
  fi

  offline_repo "$profile/airootfs/opt/intent-os/repo"

  rm -rf "$OUT/iso"
  mkarchiso -v -w "$WORK/archiso" -o "$OUT/iso" "$profile"
  (cd "$OUT/iso" && sha256sum ./*.iso > SHA256SUMS)
  # GitHub release assets must be under 2 GiB; fail here, not at publish.
  local iso size limit=$((1900 * 1024 * 1024))
  iso=$(ls "$OUT"/iso/*.iso)
  size=$(stat -c %s "$iso")
  log "ISO size: $((size / 1024 / 1024)) MiB (limit 1900 MiB)"
  if (( size > limit )); then
    echo "error: ISO is $((size / 1024 / 1024)) MiB; GitHub release assets must stay under 2 GiB" >&2
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
