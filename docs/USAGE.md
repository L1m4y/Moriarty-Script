# Detailed usage

## Execute

```bash
sudo bash moriarty.sh
```

The script requires `EUID == 0`. Non-interactive use:

```bash
sudo bash moriarty.sh --yes --profile balanced
```

## What is changed

| Phase | File or service |
| --- | --- |
| dependencies | `pacman -S --needed dnscrypt-proxy bind` |
| sysctl | `/etc/sysctl.d/99-moriarty-hardening.conf`, `/etc/sysctl.d/99-moriarty-performance.conf` |
| modules | `/etc/modprobe.d/99-moriarty-blacklist.conf` |
| identity | `/etc/NetworkManager/conf.d/00-moriarty-identity.conf` |
| profile DNS | `90-dns-none.conf` plus per-profile `ipv4/ipv6.dns` and `ignore-auto-dns` |
| DNS | `/etc/dnscrypt-proxy/dnscrypt-proxy.toml`, `/etc/resolv.conf` |
| resolved | `/etc/systemd/resolved.conf.d/99-moriarty-dns.conf` |
| avahi | `disable-publishing=yes` in `/etc/avahi/avahi-daemon.conf` |
| UFW | `net/ipv4/conf/*/rp_filter` and `log_martians` in `/etc/ufw/sysctl.conf` |

Old `garbato-*` and earlier Moriarty filenames are removed after being backed up.

## Post-run checks

```bash
sysctl -n kernel.kptr_restrict kernel.dmesg_restrict kernel.sysrq \
  net.ipv4.conf.all.rp_filter net.ipv6.conf.all.use_tempaddr
systemctl is-active dnscrypt-proxy
dig example.com @127.0.0.1 +short
dig example.com +short
getent hosts example.com
resolvectl status
ip link # MAC changes after reboot
```

## DNS path

```text
libc/NSS -> /etc/resolv.conf -> 127.0.0.1:53 (dnscrypt-proxy)
systemd-resolved stub (127.0.0.53) -> 127.0.0.1:53 (proxy)
```

`/etc/resolv.conf` deliberately points directly at dnscrypt-proxy. The resolved
drop-in exists for programs and services that use `resolve` in `nsswitch.conf`.

## Partial changes

Use component flags when required by the deployment:

- `--skip-modules`: leaves the modprobe policy untouched.
- `--skip-network`: leaves NetworkManager identity and profile settings untouched.
- `--skip-dns`: does not install `dnscrypt-proxy`/`bind`, does not write the
  `90-dns-none.conf` drop-in, and does not touch per-profile DNS or
  `/etc/resolv.conf`. If a previous run installed these files, they stay in
  place and the script warns about it.
- `--skip-avahi`: leaves Avahi publishing untouched.
- `--skip-ufw`: leaves the UFW sysctl file untouched.

## Restore

```bash
ls -lt /root | grep moriarty-backup || true
sudo ./moriarty-restore.sh --list
sudo ./moriarty-restore.sh --yes /root/moriarty-backup.20260...
```

Use `--dry-run` with restore to inspect a manifest before changing anything.
Restored service states come from `systemd-units.tsv`.

Restore cannot undo every kernel value in the same boot. In particular,
`kernel.kexec_load_disabled=1` (strict profile) stays set until the next reboot,
and modules loaded by Moriarty remain loaded. The full table is in
[THREAT-MODEL.md](THREAT-MODEL.md#reversibility).

## Uninstalling manually

Moriarty leaves installed packages installed. To remove optional packages after
restore:

```bash
sudo pacman -R dnscrypt-proxy bind
```

Only do this after restoring the DNS configuration or confirming another
resolver is active.
