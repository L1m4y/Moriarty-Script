# Compatibility notes

- Arch Linux and CachyOS only, because of `pacman`.
- Requires `systemd`, `NetworkManager`, `nmcli`, `modprobe`, and a standard
  `/etc/os-release`.
- `vm.*`, `dev.tty.legacy_tiocsti`, `kernel.io_uring_disabled`, and BPF keys may
  be absent on some kernels. These are reported as `unsupported`, not fatal unless
  the key exists and cannot be applied in mandatory mode.
- `strict` blocks `squashfs`, so Live ISOs, squashfs overlays, and some install
  media may fail unless you use `balanced` or `--skip-modules`.
- Strict mode also sets `kexec_load_disabled=1`, which cannot be unset until reboot.
- `kernel.unprivileged_bpf_disabled` is set to `2`: unprivileged BPF stays
  blocked, but the value can be reverted at runtime. Value `1` cannot be
  re-enabled until reboot and is deliberately not used, so restore remains
  meaningful.
- `--force-profile-dns` may clear static DNS and is not recommended on managed
  networks with corporate or 802.1X resolvers.
- DNS bootstrapping uses plain DNS. User DNS queries use the configured encrypted
  servers.
