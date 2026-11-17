# Intent OS

Intent OS turns a computer into a single-purpose [Intent](https://intentapp.dev/) device.
It boots a minimal Arch Linux system straight into the Intent desktop app. There is no
general desktop: terminals, packages, and the rest of the OS stay reachable from inside
Intent.

Status: design stage. See [docs/DESIGN.md](docs/DESIGN.md).

## Layout (planned)

| Path | Purpose |
|---|---|
| `iso/` | archiso profile for the live installer image |
| `installer/` | thin installer: disk, network, owner PIN |
| `packages/` | PKGBUILDs for the `intent-os` pacman repo |
| `session/` | compositor config, session units, device controls, lock |
| `update/` | staged update timer, snapshot and rollback hooks |
| `tests/` | QEMU boot-to-Intent smoke tests |

## License

Apache 2.0. See [LICENSE](LICENSE).
