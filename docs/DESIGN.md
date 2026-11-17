# Intent OS design

## 1. Goal

Boot a computer straight into the Intent desktop app. Keep a full Linux system under it.
Show no other apps. Keep the device updated and recover from failure without the owner.

## 2. Packaging model

Follow the Omarchy pattern (Arch, btrfs + snapper, ISO installer), but ship only the
base layer.

1. **pacman packages are the product.** Everything is in five packages (see README).
2. **The ISO is an offline installer.** The ISO carries a complete pacman repo for one
   pinned Arch snapshot plus the Intent OS packages. The installer needs no network and
   always installs the exact set that passed the boot test.
3. **Updates are `pacman -Syu`** against the pinned snapshot, plus the signed
   `intent-os` repo for Intent OS and Intent packages.

## 3. Use Intent as written

No changes to `cloudlands-fe` or `intentd`.

| Need | How |
|---|---|
| Intent build | `intent-desktop-bin` unpacks the released `intent_<v>_amd64.deb` into `/opt/Intent`. `bump-intent.yml` follows the stable channel. |
| `intentd` | Electron starts its bundled sidecar as usual. |
| One updater | `prepare-intent` sets `updateChannel: "disabled"` in `~/.config/Intent/local-prefs.json` before every start. |
| No app menu bar | Same file: `menuBarAutoHide: true` on first start. |
| Secrets | No keyring daemon. Electron falls back to its basic store; `intentd` uses none. |

## 4. Session

```text
greetd (autologin "intent") -> intent-os-session -> sway (kiosk config)
   session-start: swaylock first, then intent-os-session.target
       intent.service      Intent, supervised
       intent-os-idle      lock after 5 min idle and before sleep
   swaybar (top, 24 px)    network, battery, clock, Restart Intent, Restart, Shut down
```

1. **sway, not cage.** The PIN lock needs `ext-session-lock`, which cage lacks. sway also
   gives a built-in bar, so device controls need no extra process.
2. **Lock first.** `swaylock -f` returns only once the screen is locked, then Intent
   starts behind the lock. It is never visible before the PIN.
3. **PIN = the owner's Linux password.** swaylock checks it through PAM. It is also the
   `sudo` password. Root is locked.
4. **Controls** are in the top-right of the bar. Restart and Shut down ask once in a
   swaynag bar (no password). A polkit rule lets `wheel` reboot and power off from user
   services.
5. **Keys:** brightness, keyboard backlight, and volume keys work, also when locked.
   Ctrl+Cmd+Q locks. The power key suspends (it sits next to Delete on the Air).

## 5. Supervision

```mermaid
stateDiagram-v2
  [*] --> Starting
  Starting --> Healthy: Intent window visible (≤200 s)
  Starting --> Starting: check fails, restart (max 3 in 5 min)
  Starting --> Recover: start limit hit
  Healthy --> Starting: Intent exits or Restart Intent
  Recover --> Reboot: fewer than 2 reboots in 30 min
  Recover --> AskOwner: otherwise (swaynag: Try again, Restart)
  Reboot --> [*]
```

1. `intent.service` runs `ExecStartPost=intent-health`, which waits for a visible sway
   window with app id or class `intent`. A failed check fails the start.
2. On success it starts `intent-os-boot-ok.service`, which sets `boot_success=1` in
   `/efi/intent-os/grubenv`.
3. GRUB resets the flag on every boot. If a boot never reached a healthy Intent, the next
   boot shows the menu for 10 s, including **Intent OS snapshots** (grub-btrfs). Snapshots
   boot read-only through an overlay.

## 6. Updates

1. **Staged snapshot.** Devices use `archive.archlinux.org/repos/<date>`. CI builds a
   nightly image on yesterday's snapshot, installs and boots it in QEMU, and only then
   publishes `channel.env` (date + build id). Devices never move to a date that has not
   passed the test, and never move backwards.
2. **When.** `intent-os-update.timer` checks hourly. It runs only when the session's
   logind IdleHint is set (5 min idle) and the device is on AC power.
3. **Snapshots.** snap-pac takes btrfs pre/post snapshots around every pacman run.
4. **Intent** is only downloaded during the update. It installs in `prepare-intent`
   before the next Intent start, so files never change under a running app (and running
   agents are never stopped for an update). A dot on **Restart Intent** shows it is
   waiting.
5. **Reboot hint.** A pacman hook marks `/run/intent-os/reboot-required` after kernel,
   firmware, systemd, glibc, Mesa, sway, or Wi-Fi driver updates. A dot on **Restart**
   shows it. The device never reboots by itself for an update.

## 7. MacBook Air, Early 2014 (MacBookAir6,1 / 6,2)

| Part | Support |
|---|---|
| Boot | UEFI. GRUB installs to the fallback path (`--removable`), so no NVRAM writes. |
| Graphics | Intel HD 5000 (Haswell), Mesa `crocus`. VA-API through `libva-intel-driver`. |
| Wi-Fi | Broadcom BCM4360. `broadcom-wl`, prebuilt for the repo kernel; also on the ISO. |
| Suspend | Works. XHC1 and ARPT wake sources are off to stop instant wake-up. |
| Keyboard, trackpad | `hid_apple` (media keys first), `bcm5974`; tap, natural scroll, click-finger. |
| Audio | Cirrus CS4208 through PipeWire. |
| Brightness | `intel_backlight` and `smc::kbd_backlight` through brightnessctl. |
| Fan | SMC firmware control. `mbpfan` not included (AUR only). |
| Camera | Not supported (needs out-of-tree `facetimehd`). |
| Memory | 4 GB or 8 GB. zram swap at half of RAM. Run agents remotely on 4 GB models. |

## 8. Later

1. Permanent rollback command (today: boot a snapshot from the GRUB menu).
2. Disk encryption. The Air has no TPM, so LUKS would need a boot passphrase.
3. Other hardware packages. Apple Silicon on an Asahi base, reusing the session and
   update packages.
4. Crash-recovery case in the QEMU test (needs a guest agent).
