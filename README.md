# Intent OS

Intent OS turns a computer into a single-purpose [Intent](https://intentapp.dev/) device.
It boots a minimal Arch Linux system straight into the Intent desktop app. There is no
general desktop: terminals, packages, and the rest of the OS stay reachable from inside
Intent.

First target: **MacBook Air, Early 2014** (MacBookAir6,1 11-inch and 6,2 13-inch; the
Mid 2013 models use the same IDs). Other x86_64 UEFI machines should work without the
Mac hardware package.

Design: [docs/DESIGN.md](docs/DESIGN.md).

## Install on a MacBook Air (Early 2014)

1. Download the newest `intent-os-*.iso` from
   [Releases](https://github.com/intent-hq/intent-os/releases) and check it against
   `SHA256SUMS`.
2. Write it to a USB stick (8 GB or larger), for example
   `sudo dd if=intent-os.iso of=/dev/sdX bs=4M conv=fsync status=progress`.
3. Plug the stick into the Air. Hold **Option** while it starts, then pick **EFI Boot**.
4. The installer starts by itself. Join Wi-Fi (the installer downloads Intent OS), pick
   the disk, set a PIN (4 to 12 digits),
   and set the time zone. Type `erase` to confirm. **This erases macOS.**
5. Remove the stick and restart. The Air boots to the PIN screen, then Intent.

The PIN unlocks the device. Intent and its agents can run `sudo` without a password.
Move the pointer to the top edge to show the bar (Wi-Fi, battery, clock, restart, shut
down); click the network name to change Wi-Fi. Cmd+C/X/V copy, cut and paste, also in the terminal. While an agent works on the device and it is on power, it does not sleep, even with the lid closed. After an update, the undo icon in the top bar reverts it. Install coding agents from
Intent; their sign-in pages open in a small Intent window. For emergencies only, Ctrl+Alt+F2 opens a text
console.

The interface uses Inter. Touchpad clicks require a physical press; tap-to-click
is disabled by default.
The companion is off by default; owners can enable it in Intent.

Press **Cmd+Shift+3** (or **Print Screen**) to copy a screenshot to the clipboard.
Press **Cmd+Shift+4** (or **Shift+Print Screen**) to select and copy an area.

## Install on an Intel Mac with the T2 chip (2018–2020)

1. In macOS Recovery (hold Cmd+R at start), open **Startup Security Utility**. Set
   **No Security** and **Allow booting from external media**.
2. Start from the stick (hold **Option**, pick **EFI Boot**), then pick **Intent OS installer
   (Mac with T2 chip)** in the menu. Do not erase macOS first:
   the installer copies the Wi-Fi firmware from it, then erases the disk.
3. Continue as on the MacBook Air.

## Install on an Apple silicon Mac (M1, M2) — untested

Apple silicon Macs cannot start from a USB stick. Intent OS installs next to macOS with
the Asahi Linux installer. In macOS Terminal run:

```sh
curl -fsSL https://github.com/intent-hq/intent-os/releases/latest/download/install-apple-silicon.sh | sh
```

Give Intent OS at least 20 GB and choose **Intent OS**. Follow the installer's restart
steps. On first start, set the PIN and time zone; then join Wi-Fi from the top bar.
M3 and newer chips are not supported yet.

## Run in a VM on an Apple silicon Mac (UTM)

Each release has two netinstall ISOs: `*-x86_64.iso` and `*-aarch64.iso`. On an Apple
silicon Mac, use the `aarch64` one.

1. Install [UTM](https://mac.getutm.app/) and download `intent-os-*-aarch64.iso`.
2. In UTM, choose **Create a New Virtual Machine → Virtualize → Linux**, pick the ISO as
   the boot image, and give it at least 4 GB of memory, 4 CPU cores and a 32 GB disk.
3. In the VM settings, set **Display** to `virtio-gpu-pci` (not `virtio-ramfb`) and
   **Network → Network Mode** to **Emulated VLAN**. (Shared Network needs macOS vmnet
   permission and fails in some UTM builds with "cannot create vmnet interface".)
4. Start the VM. The installer works as on a PC: network, disk (the VM's disk), PIN,
   time zone, `erase`.
5. When it says Intent OS is installed, eject the ISO in UTM (CD/DVD → Clear) and press
   Enter to restart.

The aarch64 build uses Arch Linux ARM. It updates from Arch Linux ARM mirrors, which have
no tested snapshot like the x86_64 build.

## Layout

| Path | Purpose |
|---|---|
| `packages/intent-appimage` | Released Intent AppImage; seeds the owner's self-updating copy |
| `packages/intent-os-base` | Base system: kernel, btrfs + snapper, network, audio, owner tools |
| `packages/intent-os-session` | sway kiosk, PIN lock, top bar with device controls, Intent supervision |
| `packages/intent-os-update` | Staged idle-time updates and restart hints |
| `packages/intent-os-hw-macbookair6` | MacBook Air 6,x: Broadcom Wi-Fi, wake fix, video decode |
| `packages/intent-os-hw-apple-silicon` | Apple silicon (M1, M2) on Asahi Linux: kernel, m1n1/U-Boot, GPU, speakers |
| `asahi/install.sh` | macOS script that runs the Asahi installer with the Intent OS image |
| `packages/intent-os-hw-t2` | Intel Macs with the T2 chip (2018–2020): t2linux kernel, Wi-Fi firmware, audio, fans, Touch Bar |
| `iso/` | Additions to the archiso `releng` profile, including the installer |
| `build/in-container.sh` | Builds signed packages and the netinstall ISO |
| `tests/smoke.sh` | QEMU test: install, boot, Intent window visible, unlock with the PIN |
| `channel/archive-date` | Default Arch Linux Archive snapshot date |

## Build

```sh
make image    # packages + ISO in out/ (Docker, x86_64)
make smoke    # QEMU install-and-boot test (needs KVM, OVMF, socat)
make image-arm64   # aarch64 packages + ISO in out/ (aarch64 host)
make smoke-arm64   # QEMU install-and-boot test of the aarch64 ISO
make lint     # shellcheck
```

CI (`.github/workflows/build.yml`) builds, runs the boot test, and publishes only builds
that pass. It signs packages with the `INTENT_OS_SIGNING_KEY` secret and publishes the
signed pacman repo that installed devices use for Intent OS updates. Intent updates
itself.

Package signing key: `F599 5B78 7437 2B7F 456E  A124 55F5 3DF0 24F2 A49A`
(ed25519, expires 2029-11-16). Public key: [keys/intent-os.asc](keys/intent-os.asc).

## License

Apache 2.0. See [LICENSE](LICENSE).
