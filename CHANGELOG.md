# Changelog

## 2.0.0

This release corrects the claims made next to the code and removes
behavior that could leave a machine without DNS.

### Added

- `moriarty-restore.sh`, driven by `MANIFEST` from the backup tree.
- `--help`, `--version`, `--dry-run`, `--yes`, `--no-color`.
- Validation of generated dnscrypt config via `dnscrypt-proxy --check`.
- `99-performance.conf` for throughput settings, kept apart from hardening.

### Changed

- MAC/DHCP/IPv6 identity is handled once, by NetworkManager. The duplicated
  `systemd.link` phase and its `.link` files were removed.
- dnscrypt bootstrap uses Quad9 (`9.9.9.9`) and forbids system DNS fallback.
- `warn_limit` removed from the sysctl profile; kernel panics now wait 30s.
- `ufw/sysctl.conf` is aligned with the profile instead of being overridden by it.
- Verification queries `/etc/resolv.conf` for real and reports every upstream
  configured in `systemd-resolved`.
- Failures restore `resolv.conf` and the NetworkManager DNS file instead of
  leaving the machine resolver-less.
- Backups preserve symlinks and abort on error.
- README states measured counts, the actual GPL-3.0 license, and known limits.

### Removed

- Redundant defaults already applied by the kernel or `systemd`
  (`rp_filter`, `accept_source_route`, `protected_hardlinks/symlinks`,
  `randomize_va_space`, `ptrace_scope`, `ip_forward`, built-in ICMP, etc.).
- `tcp_tw_reuse`, `tcp_fastopen=server` and BBR-less performance tunables
  removed from the security profile.
- Unused `Moriarty-Logo.jpg`.
- Nonexistent `dnscrypt` owner change in the apply script.

### Known limits

- Encrypted DNS hides the resolver, not the connection destination or SNI.
- Kernel module bans block autoloading only.
- Bootstrap still happens once in clear text.
