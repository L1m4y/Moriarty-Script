# Changelog

## 2.3.4

### Fixed
- Resolver metadata verification now fails closed. If `dnscrypt-proxy -list`
  fails or exceeds the 30-second timeout, the run aborts instead of continuing
  with unverified resolvers. A missing config or a missing `timeout` command is
  also fatal. This matches the documented DNSSEC/no-log requirement; there is
  no offline fallback because the project does not keep a separately validated
  signed cache.

### Changed
- `--dry-run` now marks each phase as skipped when the matching `--skip-*`
  flag is used, instead of describing work that would not run.

### Tests
- `tests/run.sh` now asserts that apply and restore share the same lock file,
  that the transaction starts before `ensure_bbr_module`, that resolver
  metadata verification fails closed, and that `--dry-run --skip-dns` reports
  the skip.

## 2.3.3

### Fixed
- `--skip-dns` no longer writes `90-dns-none.conf`, clears per-profile DNS, or
  verifies the resolver path. The NetworkManager drop-in is only written when
  the DNS phase is enabled, and a leftover drop-in from a previous run is
  reported instead of silently kept.
- The transaction now starts before loading `tcp_bbr` and writing
  `/etc/modules-load.d/99-moriarty-bbr.conf`, so a failure in the dependency
  phase rolls those changes back instead of leaving them behind.
- Apply and restore share `/run/lock/moriarty.lock`, so the two operations can
  no longer run at the same time.
- `kernel.unprivileged_bpf_disabled` is set to `2` instead of `1`: unprivileged
  BPF stays disabled, but the value can be reverted without a reboot, which
  keeps restore meaningful. A host that already has `1` (set by 2.3.2) cannot
  change it until reboot; the run persists `2`, reports it as `pending-reboot`,
  and the next boot applies it.
- Documented reversibility per change, including `kernel.kexec_load_disabled`
  in the strict profile and modules loaded by Moriarty. `moriarty-restore.sh`
  now names an irreversible setting in its final warning.

### Documentation
- README now documents every CLI option for `moriarty.sh` and
  `moriarty-restore.sh`: profiles, component skips, force flags,
  `--no-rollback`, `--dry-run`, `--check`, and the restore options.

## 2.3.2

### Fixed
- Avahi: `disable-publishing` is now written to `[publish]`, the only section
  where avahi accepts it, and stray copies in `[server]` are removed. This
  fixes `avahi-daemon` failing with
  `Invalid configuration key "disable-publishing" in group "server"`.
- Avahi restart clears a previous `start-limit-hit`, so re-running Moriarty
  recovers a unit that an older invalid configuration left failed.
- BBR: `tcp_bbr` is loaded with `modprobe` and persisted through
  `/etc/modules-load.d/99-moriarty-bbr.conf`, so
  `net.ipv4.tcp_congestion_control=bbr` also works after a reboot. Previously
  the script only inspected the loaded-module list and reported BBR as
  unavailable.
- The sysctl summary now counts and verifies the performance profile too, so a
  performance mismatch is no longer silently ignored.

### Documentation
- Add `docs/THREAT-MODEL.md`: per-component matrix of what each feature
  protects against, from which actor, and under which conditions, including an
  explicit privacy-versus-security section.
- Expand `docs/TESTING.md` with the integration matrix that still has to be run
  on real hardware, the current CI gaps, and an evidence collection protocol.
  Pending rows are marked as such, not as passing results.

## 2.3.1

Security and reliability rework.

### Added
- Per-key sysctl apply and verification with clear `applied`, `unsupported`,
  `rejected`, and `mismatch` statuses.
- `--profile balanced|strict`.
- Component skips (`--skip-modules`, `--skip-network`, `--skip-dns`,
  `--skip-avahi`, `--skip-ufw`).
- `--check` audit mode.
- `--force-profile-dns` and `--force-profile-identity`.
- `--no-rollback`.
- SHA-256 signed manifest (version 2) with v1 backward compatibility.
- NetworkManager connection profiles and identity snapshot backup/restore.
- Systemd service-state snapshot and restore.
- Runtime sysctl-value restore.
- Legacy configuration cleanup with automatic backup.
- Resolver metadata verification using `dnscrypt-proxy -list`.
- `make check`, `make test`, tests/run.sh, SECURITY.md and additional docs.

### Changed
- Backup path is now timestamped plus a random suffix and stores META data.
- Verification uses the system resolver path and reports foreign resolved DNS.
- NetworkManager file renamed to `00-moriarty-identity.conf`; old files cleaned up.
- Sysctl files renamed to `99-moriarty-hardening.conf` and
  `99-moriarty-performance.conf`; old files cleaned up.
- Module policy renamed to `99-moriarty-blacklist.conf`; old policy cleaned up.
- Avahi and UFW handling remain clearly separate from firewall enrollment.

### Fixed
- Test suite no longer depends on a developer-local temporary directory or on
  `python3`; it uses a private temporary directory and `awk`, so the CI
  `tests` job passes on a clean `archlinux:latest` container.
- sysctl errors are no longer hidden.
- NetworkManager profile DNS changes are now backed up and restored.
- Manifest paths, ownership, mode and payload checksums are validated.
- Restore path validation now rejects symlink escapes.
- UFW sysctl alignment uses atomic writes.
- `connection.stable-id` and other identity values survive clear DNS failures.
