# Changelog

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
- Test suite no longer depends on a local `/tmp/opencode` directory or on
  `python3`; it uses a private temporary directory and `awk`, so the CI
  `tests` job passes on a clean `archlinux:latest` container.
- sysctl errors are no longer hidden.
- NetworkManager profile DNS changes are now backed up and restored.
- Manifest paths, ownership, mode and payload checksums are validated.
- Restore path validation now rejects symlink escapes.
- UFW sysctl alignment uses atomic writes.
- `connection.stable-id` and other identity values survive clear DNS failures.
