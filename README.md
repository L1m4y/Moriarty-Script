# Moriarty-Script

One-shot privacy and host-hardening profile for Arch Linux and CachyOS derivatives.

Moriarty is **not** an anonymity tool. It rotates per-boot hardware identity, forces
system DNS through a pinned encrypted resolver, tightens the kernel surface, and
restores or verifies the result.

## What it does

1. **Dependencies** – installs `dnscrypt-proxy` and `bind` (for `dig`) with pacman.
2. **Sysctl hardening** – applies 30+ tunables and verifies each effective value.
3. **Module policy** – blocks rarely used protocols/filesystems through
   `install ... /bin/false`, with optional Live-ISO-safe profiles.
4. **Per-boot identity** – NetworkManager derives MAC, DHCP client ID, DHCPv6 DUID,
   and stable IPv6 privacy addresses from one `${CONNECTION}/${BOOT}` seed.
5. **Encrypted DNS** – `dnscrypt-proxy` on `127.0.0.1:53`, verified before
   routing is changed. NM's own DNS is disabled.
6. **resolved / Avahi / UFW** – `systemd-resolved` forwards only to the proxy,
   LLMNR/mDNS are disabled, Avahi publishing is off, UFW sysctl is aligned.
7. **Verification** – sysctl values, service state, direct proxy queries, system
   resolver queries, NSS resolution, and a written report.

Every change is recorded in a manifest and can be restored, including
NetworkManager connection profiles and prior systemd service states.

## Requirements

- Arch Linux or a compatible derivative (`pacman`, `systemd`, `NetworkManager`)
- Root privileges (`sudo`)
- `dig` is provided by `bind`; phase 1 installs it if missing

## Quick use

```bash
git clone https://github.com/L1m4y/Moriarty-Script.git
cd Moriarty-Script

# review first
sudo bash moriarty.sh --dry-run

# apply with prompts
sudo bash moriarty.sh

# audit the current state without changing it
sudo bash moriarty.sh --check

# encrypted, non-interactive run
sudo bash moriarty.sh --yes --profile strict

# change only some components
sudo bash moriarty.sh --skip-modules --skip-ufw
```

Reboot after applying so the new MAC/DHCP identity and module policy take effect.

## Profiles

| Profile | Extra sysctl / module behavior |
| --- | --- |
| `balanced` (default) | kptr/dmesg, BPF/io_uring limits, redirect/ARP hardening, privacy IPv6; block protocols and rare filesystems without `squashfs`/`udf` so Linux install media can still mount |
| `strict` | Adds irreversible `kexec_load_disabled=1`, `panic_on_oops`-style oops limit, stricter perf policy, and blocks `squashfs`/`udf` |

Use `--profile strict` only when you understand the compatibility tradeoffs.

## Options

```text
-h, --help
-V, --version
-n, --dry-run
--check
-y, --yes
--profile balanced|strict
--skip-modules --skip-network --skip-dns --skip-avahi --skip-ufw
--force-profile-dns
--force-profile-identity
--no-rollback
--no-color
```

## Backup and restore

Apply creates a root-owned directory such as `/root/moriarty-backup.YYYYMMDD_HHMMSS.XXXXXX/`.
It contains:

- `MANIFEST` – allow-listed paths, `created` or `modified`, plus SHA-256 checksums
- `META` – version, profile, timestamp, hostname, kernel
- `report.txt` – per-setting status and summary
- `sysctl-runtime.tsv`, `systemd-units.tsv`, `networkmanager-profiles.tsv`,
  and `networkmanager-identity.tsv` – prior runtime and profile state

Restore:

```bash
sudo ./moriarty-restore.sh --list
sudo ./moriarty-restore.sh /root/moriarty-backup.20260...)
# or
sudo ./moriarty-restore.sh --yes --dry-run /root/moriarty-backup...
```

Restoration is pre-validated before changes and each file is replaced atomically.

Installed packages are **not** removed by restore. Some kernel changes, such as
`kexec_load_disabled=1`, cannot be reverted without reboot.

## Architecture and limits

Detailed DNS flow, NetworkManager identity behavior, sysctl policy, module policy,
transaction behavior, and compatibility notes live in `docs/ARCHITECTURE.md` and
`docs/COMPATIBILITY.md`.

Important limits:

- Encrypted DNS hides the resolver and query contents from on-path observers, but
  destinations, connection timing, TLS SNI, and HTTP/2 HPACK are still visible.
- Bootstrap DNS during startup is still plain DNS.
- Per-boot identity only applies where NetworkManager is the resolver/network
  authority; static IPs, VPN DNS, and 802.1X profiles may be skipped by default.
- UFW is **not** installed or enabled by Moriarty. Only
  `/etc/ufw/sysctl.conf` is aligned so UFW cannot override the profile.
- Module bans stop normal `modprobe` loading. Built-in modules and direct
  `insmod` are not covered.
- `kexec_load_disabled=1` in strict mode cannot be reverted during the same boot.

## Security

See `SECURITY.md` for the threat model, assumptions, and reporting.

## Tests and quality checks

```bash
make check
make test
```

CI installs `shellcheck` and `shfmt` on Arch Linux and validates all scripts plus
backup-manifest invariants. See `docs/TESTING.md`.

## License

GPL-3.0-or-later. See `LICENSE`.
