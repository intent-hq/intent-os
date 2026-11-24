#!/bin/bash
# Runs inside a privileged container with the repo at /src: archlinux:base-devel
# on x86_64, an Arch Linux ARM image on aarch64 (see the Makefile).
#   packages: build Intent OS pacman packages into out/repo
#   iso:      build the installer ISO (netinstall) into out/iso
#   all:      both
# Env: ARCHIVE_DATE (YYYY/MM/DD), BUILD_ID, INTENT_OS_SIGNING_KEY (optional,
# ASCII-armored secret key), HOST_UID (chown output for the host user).
set -euo pipefail

SRC=/src
OUT=$SRC/out
WORK=/tmp/intent-os
ARCH=$(uname -m)
# archiso is not packaged for Arch Linux ARM; aarch64 runs it from this tag.
ARCHISO_REF=v92
PACKAGES=(intent-appimage intent-os-base intent-os-session intent-os-update intent-os-bootstrap)
if [[ $ARCH == x86_64 ]]; then
  PACKAGES+=(facetimehd-dkms intent-os-hw-macbookair6 intent-os-hw-t2)
else
  PACKAGES+=(intent-os-hw-apple-silicon)
fi
# Apple silicon (Asahi Linux): packages from asahi-alarm; the image is a zip
# for the Asahi installer, which runs from macOS.
# shellcheck disable=SC2016 # pacman expands $arch
ASAHI_SERVER='https://github.com/asahi-alarm/asahi-alarm/releases/download/$arch'
ASAHI_ESP_VOLID=2abf9f91
ASAHI_ESP_BYTES=524288000
ASAHI_ROOT_MIB=6144
# macOS system firmware versions the Asahi installer can set up (from asahi-alarm).
ASAHI_SUPPORTED_FW='["12.3", "12.3.1", "13.5", "14.8.3"]'
# T2 Macs (2018-2020): t2linux packages, copied into the signed intent-os repo
# so devices get a tested, signed set. The arch-mact2 repo itself is unsigned;
# each file is checked against the sha256 in its database.
T2_REPO=https://mirror.funami.tech/arch-mact2/os/x86_64
T2_PACKAGES=(linux-t2 linux-t2-headers apple-bcm-firmware-fetcher apple-t2-audio-config t2fanrd tiny-dfr)

: "${ARCHIVE_DATE:?set ARCHIVE_DATE, for example 2026/11/15}"
: "${BUILD_ID:?set BUILD_ID}"
[[ $ARCHIVE_DATE =~ ^[0-9]{4}/[0-9]{2}/[0-9]{2}$ ]] || { echo "bad ARCHIVE_DATE" >&2; exit 1; }

log() { printf '\n==> %s\n' "$*"; }

prepare() {
  log "Preparing build container"
  pacman-key --init >/dev/null
  if [[ $ARCH == aarch64 ]]; then
    pacman-key --populate archlinuxarm >/dev/null
    # Avoid mirror.archlinuxarm.org: per-request Geo-IP redirects can mix a
    # fresh package database with a stale backend mirror (404). Direct mirrors
    # keep database and package downloads on the same server, with failover.
    cat > /etc/pacman.d/mirrorlist <<'MIRRORS'
Server = http://fl.us.mirror.archlinuxarm.org/$arch/$repo
Server = http://ca.us.mirror.archlinuxarm.org/$arch/$repo
Server = http://nj.us.mirror.archlinuxarm.org/$arch/$repo
Server = http://de.mirror.archlinuxarm.org/$arch/$repo
Server = http://de4.mirror.archlinuxarm.org/$arch/$repo
Server = http://dk.mirror.archlinuxarm.org/$arch/$repo
MIRRORS
    # The imported rootfs keeps CheckSpace, which fails on overlay mounts.
    sed -i 's/^CheckSpace/#CheckSpace/' /etc/pacman.conf
    pacman -Syu --noconfirm --needed base-devel git arch-install-scripts btrfs-progs \
      dosfstools gptfdisk grub libisoburn erofs-utils squashfs-tools mtools zip >/dev/null
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
    # The aarch64 ISO installs intent-os-bootstrap from the signed local repo.
    pacman-key --add "$OUT/keyring/intent-os.gpg" >/dev/null
    pacman-key --lsign-key "$KEY_ID" >/dev/null
  fi
}

fetch_t2_packages() {
  log "Fetching T2 Mac packages"
  local db=$WORK/t2 p desc file sum
  rm -rf "$db" && mkdir -p "$db"
  curl -fsSL --retry 3 -o "$db/arch-mact2.db" "$T2_REPO/arch-mact2.db"
  tar -xf "$db/arch-mact2.db" -C "$db"
  for p in "${T2_PACKAGES[@]}"; do
    desc=$(for d in "$db"/*/desc; do
      if [[ $(sed -n '/^%NAME%$/{n;p;q}' "$d") == "$p" ]]; then echo "$d"; fi; done | head -n1)
    [[ -n $desc ]] || { echo "error: $p is not in arch-mact2" >&2; exit 1; }
    file=$(sed -n '/^%FILENAME%$/{n;p;q}' "$desc")
    sum=$(sed -n '/^%SHA256SUM%$/{n;p;q}' "$desc")
    curl -fsSL --retry 3 -o "$OUT/repo/$file" "$T2_REPO/$file"
    echo "$sum  $OUT/repo/$file" | sha256sum -c --quiet -
    if [[ -n $KEY_ID ]]; then
      gpg --batch --yes --detach-sign --no-armor -u "$KEY_ID" -o "$OUT/repo/$file.sig" "$OUT/repo/$file"
    fi
  done
}

build_packages() {
  log "Building packages"
  rm -rf "$OUT/repo" "$WORK/pkgbuild"
  mkdir -p "$OUT/repo" "$WORK/pkgbuild" "$WORK/src"
  chown builder "$OUT/repo" "$WORK/src"
  local p
  for p in "${PACKAGES[@]}"; do
    cp -r "$SRC/packages/$p" "$WORK/pkgbuild/$p"
    # Each build gets a newer version (0.1.0.<build time>), so installed devices
    # upgrade only the Intent OS packages that pacman sees as new. Repackaged
    # upstream software (intent-appimage, facetimehd-dkms) keeps its version.
    [[ $p == intent-appimage || $p == facetimehd-dkms ]] ||
      sed -i "s/^pkgver=\(.*\)$/pkgver=\1.${BUILD_ID%%-*}/" "$WORK/pkgbuild/$p/PKGBUILD"
    chown -R builder "$WORK/pkgbuild/$p"
    (cd "$WORK/pkgbuild/$p" &&
      sudo -u builder env PKGDEST="$OUT/repo" SRCDEST="$WORK/src" PKGEXT=.pkg.tar.zst \
        makepkg -fd --noconfirm "${SIGN_ARGS[@]}")
  done
  if [[ $ARCH == x86_64 ]]; then fetch_t2_packages; fi
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
  # The live system runs the T2 kernel: it is Arch's kernel plus T2 Mac drivers,
  # so the same stick also has a keyboard and Wi-Fi on T2 Macs.
  pacman -U --noconfirm --needed "$OUT"/repo/linux-t2-[0-9]*.pkg.tar.zst \
    "$OUT"/repo/linux-t2-headers-[0-9]*.pkg.tar.zst >/dev/null
  pacman -S --noconfirm --needed broadcom-wl-dkms \
    linux-firmware-intel linux-firmware-atheros linux-firmware-mediatek >/dev/null
  local linux_ver kdir wl dir=$WORK/live-pkg
  linux_ver=$(pacman -Q linux-t2 | awk '{print $2}')
  kdir=$(find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d -exec test -e '{}/updates/dkms' ';' -print | head -n1)
  wl=$(find "$kdir/updates/dkms" -name 'wl.ko*' | head -n1)
  [[ -n $wl ]] || { echo "error: dkms did not build wl for $kdir" >&2; exit 1; }
  rm -rf "$dir" "$WORK/live-repo"
  mkdir -p "$dir/root" "$WORK/live-repo"
  install -Dm644 "$wl" "$dir/root${wl}"
  # broadcom-wl's own modprobe.d file also blacklists brcmfmac, which other
  # Macs (BCM43602 and newer) need. Block only the drivers that fight wl for
  # the Air's BCM4360.
  printf 'blacklist %s\n' b43 b43legacy ssb bcma bcm43xx \
    | install -Dm644 /dev/stdin "$dir/root/usr/lib/modprobe.d/intent-os-live-wl.conf"
  # wl also claims newer Broadcom chips (the BCM43602 in 2016-2017 MacBook
  # Pros) and then fights brcmfmac. Never autoload it; udev loads it only for
  # the Air's BCM4360 (14e4:43a0).
  echo 'blacklist wl' >> "$dir/root/usr/lib/modprobe.d/intent-os-live-wl.conf"
  install -Dm644 /dev/stdin "$dir/root/usr/lib/udev/rules.d/60-intent-os-live-wl.rules" <<'RULE'
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x14e4", ATTR{device}=="0x43a0", RUN+="/usr/bin/modprobe wl"
RULE
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
depends=("linux-t2=$linux_ver")
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
  log "Building installer ISO ($ARCH)"
  local profile=$WORK/profile mkarchiso=mkarchiso console=ttyS0 limit_mib=560
  rm -rf "$profile" "$WORK/archiso"
  if [[ $ARCH == aarch64 ]]; then
    rm -rf "$WORK/archiso-src"
    git clone -q --depth 1 --branch "$ARCHISO_REF" \
      https://gitlab.archlinux.org/archlinux/archiso.git "$WORK/archiso-src"
    cp -r "$WORK/archiso-src/configs/baseline" "$profile"
    mkarchiso=$WORK/archiso-src/archiso/mkarchiso
    # archiso's GRUB module list includes x86-only modules (at_keyboard, ...);
    # keep only the ones that exist for the target.
    sed -i '/usbserial_pl2303 usbserial_usbdebug video xfs zstd)/a\
    local _m _have=(); for _m in "${grubmodules[@]}"; do [[ -e "/usr/lib/grub/${grub_target}/${_m}.mod" ]] \&\& _have+=("$_m"); done; grubmodules=("${_have[@]}")' \
      "$mkarchiso"
    grep -q '_have+=' "$mkarchiso" || { echo "error: could not patch mkarchiso GRUB modules" >&2; exit 1; }
    console=ttyAMA0 limit_mib=450
    # Arch Linux ARM repos; UEFI GRUB only (no BIOS on arm64).
    cp /etc/pacman.conf "$profile/pacman.conf"
    sed -i "/^bootmodes=(/,/)/c\\bootmodes=('uefi.grub')" "$profile/profiledef.sh"
    # The Arch Linux ARM kernel cannot mount EROFS; use squashfs for the live root.
    sed -i -e 's/^airootfs_image_type=.*/airootfs_image_type="squashfs"/' \
      -e "s/^airootfs_image_tool_options=.*/airootfs_image_tool_options=('-comp' 'xz' '-b' '1M')/" \
      "$profile/profiledef.sh"
  else
    cp -r /usr/share/archiso/configs/baseline "$profile"
    build_live_package
    # The boot menu reads the machine model (SMBIOS) to set per-model kernel
    # arguments; archiso's GRUB image leaves that module out.
    cp "$(command -v mkarchiso)" "$WORK/mkarchiso"
    mkarchiso=$WORK/mkarchiso
    sed -i 's/grubmodules=(all_video /&smbios /' "$mkarchiso"
    grep -q 'grubmodules=(all_video smbios ' "$mkarchiso" || { echo "error: could not add smbios to mkarchiso GRUB modules" >&2; exit 1; }
  fi

  # Our own package list and services; drop baseline's cloud and VM tooling.
  cp "$SRC/iso/packages.$ARCH" "$profile/packages.$ARCH"
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
  # aarch64: intent-os-bootstrap exposes /boot/Image as vmlinuz-linux for
  # mkarchiso. x86_64: the T2 kernel and firmware fetcher come from intent-os.
  cat >> "$profile/pacman.conf" <<CONF

[intent-os]
SigLevel = Optional TrustAll
Server = file://$OUT/repo
CONF
  if [[ $ARCH == x86_64 ]]; then
    cat >> "$profile/pacman.conf" <<CONF

[intent-os-live]
SigLevel = Optional TrustAll
Server = file://$WORK/live-repo
CONF
    # Boot the live system with the T2 kernel. T2 Macs also need IOMMU
    # passthrough, which upsets other Macs' Wi-Fi, so only a second menu
    # entry sets it.
    find "$profile/efiboot" "$profile/grub" "$profile/syslinux" -type f \
      \( -name '*.conf' -o -name '*.cfg' \) -exec sed -i \
      -e 's/vmlinuz-linux\b/vmlinuz-linux-t2/g' -e 's/initramfs-linux\.img/initramfs-linux-t2.img/g' {} +
    # shellcheck disable=SC2016 # ${archiso_platform} is GRUB's, matched literally
    sed -i 's/^menuentry "Arch Linux (%ARCH%, ${archiso_platform})"/menuentry "Intent OS installer"/' "$profile/grub/grub.cfg"
    cat >> "$profile/grub/grub.cfg" <<'GRUB'

menuentry "Intent OS installer (Mac with T2 chip, 2018-2020)" --class arch --class os --id 't2' {
    set gfxpayload=keep
    linux /%INSTALL_DIR%/boot/%ARCH%/vmlinuz-linux-t2 archisobasedir=%INSTALL_DIR% archisosearchuuid=%ARCHISO_UUID% intel_iommu=on iommu=pt pm_async=off
    initrd /%INSTALL_DIR%/boot/%ARCH%/initramfs-linux-t2.img
}
GRUB
    grep -rq vmlinuz-linux-t2 "$profile/grub" || { echo "error: live boot entries still use vmlinuz-linux" >&2; exit 1; }
    # Apple's EFI text console often stays blank, so GRUB's menu (and the T2
    # entry) was invisible on Macs. Draw the menu with the graphics terminal.
    sed -i 's/^\(\s*\)terminal_output console$/\1terminal_output gfxterm/' "$profile/grub/grub.cfg"
    grep -q 'terminal_output gfxterm' "$profile/grub/grub.cfg" || { echo "error: GRUB menu is not on gfxterm" >&2; exit 1; }
    # The Chuwi MiniBook X has a portrait panel mounted sideways. Tell Linux,
    # so the installer console is upright (keep in sync with intent-os-install).
    # GRUB variables below are written literally, not expanded by this shell.
    # shellcheck disable=SC2016
    sed -i '/^# Set default menu entry/i\
insmod smbios\
insmod regexp\
if smbios --type 1 --get-string 4 --set intent_os_vendor; then\
if smbios --type 1 --get-string 5 --set intent_os_product; then\
if regexp "^CHUWI" "$intent_os_vendor"; then\
if regexp "^MiniBook X *\\$" "$intent_os_product"; then\
set intent_os_hw_args="video=DSI-1:panel_orientation=right_side_up fbcon=rotate:1"\
fi\
fi\
fi\
fi\
' "$profile/grub/grub.cfg"
    # shellcheck disable=SC2016
    sed -i 's/archisosearchuuid=%ARCHISO_UUID%/& ${intent_os_hw_args}/' "$profile/grub/grub.cfg"
    # shellcheck disable=SC2016
    if ! grep -q 'set intent_os_hw_args=' "$profile/grub/grub.cfg" \
      || ! grep -qF 'archisosearchuuid=%ARCHISO_UUID% ${intent_os_hw_args}' "$profile/grub/grub.cfg"; then
      echo "error: could not add per-model kernel arguments to the GRUB menu" >&2
      exit 1
    fi
  fi

  # Serial console for the QEMU boot test. tty0 comes last so it is the main
  # console: boot errors and rescue prompts appear on screen, not only on serial.
  find "$profile/efiboot" "$profile/grub" "$profile/syslinux" -type f \
    \( -name '*.conf' -o -name '*.cfg' \) \
    -exec sed -i "s/archisosearchuuid=%ARCHISO_UUID%/& console=$console,115200 console=tty0/" {} + 2>/dev/null || true

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
  # The installer downloads from the signed intent-os repo plus, on x86_64,
  # the pinned Arch snapshot (Arch Linux ARM has no archive: normal mirrors).
  local intent_siglevel="Optional TrustAll" distro_repos
  if [[ -d $OUT/keyring ]]; then
    cp "$OUT/keyring/intent-os.gpg" "$OUT/keyring/intent-os-trusted" "$etc/"
    intent_siglevel="Required DatabaseRequired"
  fi
  if [[ $ARCH == aarch64 ]]; then
    distro_repos=$'[core]\nInclude = /etc/pacman.d/mirrorlist\n\n[extra]\nInclude = /etc/pacman.d/mirrorlist\n\n[alarm]\nInclude = /etc/pacman.d/mirrorlist'
  else
    write_mirrorlist "$etc/mirrorlist"
    distro_repos=$'[core]\nInclude = /etc/intent-os/mirrorlist\n\n[extra]\nInclude = /etc/intent-os/mirrorlist'
  fi
  cat > "$etc/pacman-install.conf" <<CONF
[options]
Architecture = $ARCH
SigLevel = Required DatabaseOptional
ParallelDownloads = 5

[intent-os]
SigLevel = $intent_siglevel
Server = https://github.com/intent-hq/intent-os/releases/download/repo-\$arch

$distro_repos
CONF

  rm -rf "$OUT/iso"
  "$mkarchiso" -v -w "$WORK/archiso" -o "$OUT/iso" "$profile"
  (cd "$OUT/iso" && sha256sum ./*.iso > SHA256SUMS)
  log "Largest parts of the live system"
  du -x -m --max-depth=5 "$WORK/archiso/$ARCH/airootfs/usr" 2>/dev/null | sort -n | tail -n 25
  # The netinstall image must stay small; fail here, not at publish.
  local iso size limit=$((limit_mib * 1024 * 1024))
  iso=$(ls "$OUT"/iso/*.iso)
  size=$(stat -c %s "$iso")
  log "ISO size: $((size / 1024 / 1024)) MiB (limit $limit_mib MiB)"
  if (( size > limit )); then
    echo "error: ISO is $((size / 1024 / 1024)) MiB; the netinstall image must stay under $limit_mib MiB" >&2
    exit 1
  fi
}

trust_asahi_alarm() {
  pacman-key --list-keys 2>/dev/null | grep -qi asahi && return 0
  local db=$WORK/asahi-db desc file
  rm -rf "$db" && mkdir -p "$db"
  curl -fsSL --retry 3 -o "$db/asahi-alarm.db" "${ASAHI_SERVER/\$arch/aarch64}/asahi-alarm.db"
  tar -xf "$db/asahi-alarm.db" -C "$db"
  desc=$(for d in "$db"/*/desc; do
    if [[ $(sed -n '/^%NAME%$/{n;p;q}' "$d") == asahi-alarm-keyring ]]; then echo "$d"; fi; done | head -n1)
  file=$(sed -n '/^%FILENAME%$/{n;p;q}' "$desc")
  curl -fsSL --retry 3 -o "$db/$file" "${ASAHI_SERVER/\$arch/aarch64}/$file"
  echo "$(sed -n '/^%SHA256SUM%$/{n;p;q}' "$desc")  $db/$file" | sha256sum -c --quiet -
  pacman -U --noconfirm "$db/$file" >/dev/null
  pacman-key --populate asahi-alarm >/dev/null
}

build_asahi_image() {
  [[ $ARCH == aarch64 ]] || { echo "error: the Apple silicon image builds on aarch64" >&2; exit 1; }
  log "Building the Apple silicon (Asahi) image"
  trust_asahi_alarm
  # The installer reads its package config and the Intent OS key from /etc/intent-os.
  local etc=/etc/intent-os intent_siglevel="Optional TrustAll"
  mkdir -p "$etc"
  if [[ -d $OUT/keyring ]]; then
    cp "$OUT/keyring/intent-os.gpg" "$OUT/keyring/intent-os-trusted" "$etc/"
    intent_siglevel="Required DatabaseRequired"
  fi
  cat > "$etc/pacman-install.conf" <<CONF
[options]
Architecture = aarch64
SigLevel = Required DatabaseOptional
ParallelDownloads = 5

[intent-os]
SigLevel = $intent_siglevel
Server = https://github.com/intent-hq/intent-os/releases/download/repo-\$arch

[asahi-alarm]
Server = $ASAHI_SERVER

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist

[alarm]
Include = /etc/pacman.d/mirrorlist
CONF

  local dir=$WORK/asahi esp_dev root_dev name="intent-os-$BUILD_ID-apple-silicon"
  rm -rf "$dir" && mkdir -p "$dir/pkg/esp" "$OUT/asahi"
  truncate -s "$ASAHI_ESP_BYTES" "$dir/esp.img"
  truncate -s "${ASAHI_ROOT_MIB}M" "$dir/pkg/root.img"
  esp_dev=$(losetup -f --show "$dir/esp.img")
  root_dev=$(losetup -f --show "$dir/pkg/root.img")
  printf '%s\n' "ESP_DEV=$esp_dev" "ROOT_DEV=$root_dev" IMAGE=1 FIRSTBOOT=1 TIMEZONE=UTC \
    HW=intent-os-hw-apple-silicon "REPO=file://$OUT/repo" "ESP_VOLID=$ASAHI_ESP_VOLID" > "$dir/install.conf"
  INTENT_OS_INSTALL_CONFIG=$dir/install.conf bash "$SRC/iso/airootfs/usr/local/bin/intent-os-install"
  mkdir -p "$dir/mnt"
  mount "$esp_dev" "$dir/mnt"
  cp -a "$dir/mnt/." "$dir/pkg/esp/"
  umount "$dir/mnt"
  losetup -d "$esp_dev" "$root_dev"
  [[ -s $dir/pkg/esp/m1n1/boot.bin && -s $dir/pkg/esp/EFI/BOOT/BOOTAA64.EFI ]] ||
    { echo "error: the ESP lacks m1n1/boot.bin or EFI/BOOT/BOOTAA64.EFI" >&2; exit 1; }
  rm -f "$OUT/asahi/$name.zip"
  (cd "$dir/pkg" && zip -1 -q -r "$OUT/asahi/$name.zip" esp root.img)

  cat > "$OUT/asahi/installer_data.json" <<JSON
{
  "os_list": [
    {
      "name": "Intent OS",
      "default_os_name": "Intent OS",
      "boot_object": "m1n1.bin",
      "next_object": "m1n1/boot.bin",
      "package": "https://github.com/intent-hq/intent-os/releases/download/iso-$BUILD_ID/$name.zip",
      "supported_fw": $ASAHI_SUPPORTED_FW,
      "extras": {},
      "partitions": [
        {
          "name": "EFI",
          "type": "EFI",
          "size": "${ASAHI_ESP_BYTES}B",
          "format": "fat",
          "volume_id": "0x$ASAHI_ESP_VOLID",
          "copy_firmware": true,
          "copy_installer_data": true,
          "source": "esp"
        },
        {
          "name": "Root",
          "type": "Linux",
          "size": "$((ASAHI_ROOT_MIB * 1024 * 1024))B",
          "expand": true,
          "image": "root.img"
        }
      ]
    }
  ]
}
JSON
  cp "$SRC/asahi/install.sh" "$OUT/asahi/install-apple-silicon.sh"
  (cd "$OUT/asahi" && sha256sum "$name.zip" > SHA256SUMS.apple-silicon)
  log "Apple silicon image: $(du -h "$OUT/asahi/$name.zip" | cut -f1)"
}

prepare
case ${1:-all} in
  packages) build_packages ;;
  iso) build_iso ;;
  asahi) build_asahi_image ;;
  all) build_packages; build_iso ;;
  *) echo "usage: $0 packages|iso|asahi|all" >&2; exit 2 ;;
esac
[[ -n ${HOST_UID:-} ]] && chown -R "$HOST_UID" "$OUT"
log "Done: $OUT"
