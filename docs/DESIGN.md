# Intent OS design (draft)

## 1. Goal

Boot a computer straight into the Intent desktop app. Keep a full Linux system under it.
Show no other apps. Keep the device updated and recover from failure without the owner.

## 2. Packaging model

Follow the Omarchy pattern, but ship only the base layer.

1. **A pacman repo is the product.** All Intent OS parts are pacman packages in an
   `intent-os` repo hosted on GitHub Releases:
   1. `intent-os-base`: meta-package. Kernel, firmware, NetworkManager, PipeWire, Mesa,
      btrfs tools, snapper.
   2. `intent-os-session`: compositor config, session units, lock screen, device-control
      helper, supervisor.
   3. `intent-os-update`: staged update timer, snapshot hooks, boot counting.
   4. `intent-desktop-bin`: repackages the released Linux build of Intent (Electron app
      plus the bundled `intentd` sidecar). No source changes.
   5. `intent-os-hw-*`: optional hardware packages, for example `intent-os-hw-macbookair`
      (Broadcom `wl`, `mbpfan`, FaceTime HD camera).
2. **The ISO is only an installer.** An archiso profile boots a live image that runs a
   thin installer: pick a disk, join Wi-Fi, set the owner PIN. The installer runs
   `archinstall` with a fixed config, adds the `intent-os` repo, and installs the
   packages above. After that, the ISO is no longer needed.
3. **Updates are only `pacman -Syu`.** Because everything is a package, OS and Intent
   updates use one path.

## 3. Use Intent as written

| Need | Existing Intent feature | Change needed |
|---|---|---|
| Linux build, x64 and arm64 | AppImage and deb in `electron-builder.yml` | None. Repackage the release. |
| Daemon lifecycle | Electron starts the bundled `intentd` sidecar | None. |
| Terminals, sudo, agent install | Integrated terminals | None. |
| Fullscreen restore | `window.ts` saves and restores fullscreen | None. |
| One updater | In-app updater has a `disabled` channel | Set `disabled` by default on Intent OS (config or env). Small. |
| Device controls (top right) | Linux uses the native frame today | Optional small gated hook. See section 5. |
| Restart-needed hint | None | Read a flag file. Small, same hook. |

## 4. Session stack

```text
systemd -> greetd (autologin owner) -> sway (kiosk config) -> Intent (Wayland, fullscreen)
                                         |-> swaylock-style PIN lock (ext-session-lock)
                                         |-> swayidle (lock on idle and resume)
                                         |-> intent-os-controls (layer-shell, top right)
```

1. **Compositor: sway with a locked-down config.** No bar, no launcher, no keybinds that
   open apps. One rule: Intent windows are fullscreen. Sway is preferred over `cage`
   because `cage` lacks the session-lock and layer-shell protocols that the PIN lock and
   the device controls need.
2. **Intent runs native Wayland** (`--ozone-platform=wayland`). Fallback to XWayland on
   GPUs where this fails.
3. **PIN lock.** The PIN is the owner's Linux password. One secret covers lock, sudo, and
   (when present) TPM2 disk unlock. The lock screen draws a numeric keypad.

## 5. Device controls

Two options:

1. **Layer-shell overlay (no Intent change).** A tiny GTK4 layer-shell window in the top
   right shows Restart Intent, Restart, Shut down. It can overlap Intent UI.
2. **Hook in Intent (one small FE change).** When `INTENT_OS=1`, Linux windows render
   these buttons where window controls go and call a local helper.

Start with option 1. Move to option 2 only if the overlap is bad.

Actions use `systemctl --user restart intent-session`, `systemctl reboot`, and
`systemctl poweroff`. A polkit rule lets the owner run them with no prompt.

## 6. Supervision

1. `intent-session.service` (user unit) runs Intent. `Restart=always`,
   `StartLimitBurst=3`.
2. Health check: a watcher on sway IPC confirms an `app_id=Intent` window exists and is
   fullscreen within N seconds of each start.
3. Escalation: three failed starts -> reboot. Boot counting (systemd-boot `+3` entries or
   a counter in `/var/lib/intent-os`) stops loops: after two failed boots, boot the last
   good snapshot.

## 7. Updates and rollback

Arch is rolling, so we stage it.

1. **Pinned mirror.** Devices point at a dated Arch Linux Archive snapshot, not live
   mirrors. CI advances the date only after the QEMU smoke test passes (boot, Intent
   fullscreen, terminal opens).
2. **Snapshots.** btrfs root plus snapper. A pacman hook takes a snapshot before every
   transaction. Boot entries list snapshots (limine or grub-btrfs), as Omarchy does.
3. **When.** A systemd timer runs updates only when logind reports idle, on AC power.
4. **Reboot needed.** If the running kernel is not installed anymore, or core libraries
   changed, write `/run/intent-os/reboot-required`. The restart control shows a hint.
   Never reboot by itself.

## 8. Hardware

| Target | Base | Status |
|---|---|---|
| x86_64 Intel and AMD | Arch Linux | Phase 1 |
| 11-inch MacBook Air (2013-2015) | Arch + `intent-os-hw-macbookair` | First device |
| Apple Silicon M1/M2 | Asahi (Fedora Asahi Remix today) | Later. Not Arch. |
| Generic arm64 | Arch Linux ARM | Later. Board-specific. |

Keep `intent-os-session` and `intent-os-update` distro-neutral (systemd units, sway
config, shell scripts). Then an Apple Silicon image can reuse them on the Asahi base.

## 9. Open questions

1. Exact first MacBook Air model and RAM. 4 GB is tight for Electron plus local agents;
   remote agents should be the default there.
2. Disk encryption. Old Macs have no TPM, so LUKS would need a separate boot passphrase.
3. Owner-installed packages versus clean rollback. Proposal: user tools go in `$HOME`
   (mise, npm prefix) so system rollback does not remove them.
4. Factory reset and backup.
