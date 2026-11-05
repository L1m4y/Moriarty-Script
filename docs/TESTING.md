# Testing

## Automated checks (CI)

```bash
make check       # syntax + shellcheck + shfmt
make test        # tests/run.sh
```

`tests/run.sh` validates CLI behavior, and — when run as root — creates
synthetic v2 backups to check manifest checksums, ownership, permissions,
path allow-listing, and symlink rejection. It uses a private temporary
directory and has no dependency beyond bash, coreutils, `awk`, and `util-linux`.

CI runs two jobs: shellcheck/shfmt on Ubuntu, and `tests/run.sh` as root inside
an `archlinux:latest` container.

### What CI does not cover

- The container has no systemd, no NetworkManager, no avahi, and no kernel
  module tree. Everything behind `DRY_RUN=0` in the apply path (writing sysctl,
  restarting units, reloading NetworkManager, starting dnscrypt, restoring
  files) is never exercised.
- Restore tests are always `--dry-run`. No test copies files back or takes the
  restore lock.
- There is no coverage of `--check`, `--profile`, `--force-profile-*`,
  `--skip-*`, or `--no-rollback`.
- Nothing is tested against real hardware, Wi-Fi, IPv6, 802.1X, or a reboot.

CI proves that the code is syntactically valid and that the manifest validation
logic behaves as intended. It does not prove that a full apply works.

## Integration matrix

The following scenarios must be exercised on a real Arch installation. None of
them has been recorded in this repository yet; the status column intentionally
says **pending** and must not be read as a passing result.

| ID | Scenario | Setup | Key checks | Status |
|----|----------|-------|------------|--------|
| I1 | Clean install, wired, DHCP v4 | Fresh Arch + NetworkManager, Ethernet | apply completes, DNS through dnscrypt, `--check` clean, no failed units | pending |
| I2 | Wi-Fi WPA2/WPA3 | Wireless profile, NetworkManager | same as I1; randomized MAC on the wireless device; no DHCP hostname sent | pending |
| I3 | IPv6 SLAAC | Network with router advertisements | privacy/temporary addresses, no EUI-64 IID, DNS over IPv6 still loopback | pending |
| I4 | Static address profile | Manual IPv4/IPv6 profile | default run skips the profile with a warning; `--force-profile-dns` clears DNS and keeps connectivity | pending |
| I5 | Corporate 802.1X / captive portal | WPA-Enterprise or portal network | 802.1X profile skipped; portal reachable; no silent DNS bypass | pending |
| I6 | Reboot persistence | Reboot after a clean apply | sysctl values, dnscrypt, resolved, NM identity, avahi, BBR survive; MAC and DHCP identity rotate | pending |
| I7 | Interrupted apply | SIGINT/SIGKILL between phases | next run works; a failed phase rolls back resolver files unless `--no-rollback` | pending |
| I8 | Restore | Apply, then `moriarty-restore.sh` | files, NM profiles, runtime sysctl, and unit states return; DNS keeps working | pending |
| I9 | Upstream failure | Block the DNSCrypt/DoH upstreams | no plaintext fallback; failure is explicit | pending |
| I10 | BBR | Kernel with `tcp_bbr` as a module | module loads, `bbr` is active, `/etc/modules-load.d/99-moriarty-bbr.conf` exists, survives reboot | pending |
| I11 | Avahi | Avahi installed and enabled | config accepted, service and socket active, `disable-publishing` in `[publish]` only | pending |
| I12 | Identity rotation | Two reboots on the same network | MAC and DHCP identifiers change across boots, stable within a boot | pending |

## How to record evidence

For each row, attach a short, sanitized report to an issue, a release note, or a
file under `docs/evidence/`. Do not paste raw machine output without removing
hostname, MAC addresses, public IPs, SSIDs, and usernames.

Record at least:

```bash
git rev-parse --short HEAD
bash moriarty.sh --version
uname -r
nmcli --version
dnscrypt-proxy -version
```

Then the result of the run and of the verification:

```bash
sudo bash moriarty.sh
sudo bash moriarty.sh --check
systemctl --failed
resolvectl status
ip -brief address
nmcli connection show
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc
```

For I6 and I12, repeat the relevant commands after a reboot and note what
changed. For I7 and I8, keep the backup directory path and the restore output.

## Status

As of the last documentation update, the repository contains no recorded
real-hardware results: only the automated CI checks above. Treat the matrix as
a protocol to follow, not as evidence that has already been collected.
