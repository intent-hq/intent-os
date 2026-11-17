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
4. The installer starts by itself. Join Wi-Fi, pick the disk, set a PIN (4 to 12 digits),
   and set the time zone. Type `erase` to confirm. **This erases macOS.**
5. Remove the stick and restart. The Air boots to the PIN screen, then Intent.

The PIN unlocks the device and is the password for `sudo`.

To add coding agents, click **Terminal** in the top bar and pick one from the menu.

## Layout

| Path | Purpose |
|---|---|
| `packages/intent-appimage` | Released Intent AppImage; seeds the owner's self-updating copy |
| `packages/intent-os-base` | Base system: kernel, btrfs + snapper, network, audio, owner tools |
| `packages/intent-os-session` | sway kiosk, PIN lock, top bar with device controls, Intent supervision |
| `packages/intent-os-update` | Staged idle-time updates and restart hints |
| `packages/intent-os-hw-macbookair6` | MacBook Air 6,x: Broadcom Wi-Fi, wake fix, video decode |
| `iso/` | Additions to the archiso `releng` profile, including the installer |
| `build/in-container.sh` | Builds packages, the offline repo, and the ISO |
| `tests/smoke.sh` | QEMU test: install, boot, Intent window visible, unlock with the PIN |
| `channel/archive-date` | Default Arch Linux Archive snapshot date |

## Build

```sh
make image    # packages + ISO in out/ (Docker, x86_64)
make smoke    # QEMU install-and-boot test (needs KVM, OVMF, socat)
make lint     # shellcheck
```

CI (`.github/workflows/build.yml`) builds, runs the boot test, and publishes only builds
that pass. Set the `INTENT_OS_SIGNING_KEY` secret to publish the signed pacman repo that
installed devices use for Intent OS updates. Intent updates itself.

## License

Apache 2.0. See [LICENSE](LICENSE).
