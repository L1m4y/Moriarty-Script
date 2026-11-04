# Architecture

## Resolver flow

```text
application
  -> NSS (resolve/files/dns)
  -> /etc/resolv.conf (nameserver 127.0.0.1)
  -> dnscrypt-proxy
  -> DoH/DNSCrypt upstreams
  -> bootstrap plain DNS (once, only if required)
```

Direct connections and `/etc/resolv.conf` are used intentionally; `resolvectl`
scans system-resolved upstreams and warns if anything other than loopback remains.

## Network identity

NetworkManager uses:

```ini
connection.stable-id=${CONNECTION}/${BOOT}
ethernet.cloned-mac-address=stable
wifi.cloned-mac-address=stable
ipv4.dhcp-client-id=stable
ipv4.dhcp-send-hostname=false
ipv6.dhcp-send-hostname=false
ipv6.dhcp-duid=ll
ipv6.addr-gen-mode=stable-privacy
ipv6.ip6-privacy=2
```

Global defaults apply to profiles without explicit values. `--force-profile-identity`
sets these values on every Ethernet/Wi-Fi profile and backs up the previous values.

## Backups and restoration

- Backups use `cp -aT` to preserve links and attributes.
- `write_file` stages a temporary file and renames it atomically.
- The manifest contains only allow-listed paths and SHA-256 hashes (version 2).
- Runtime sysctl, systemd unit state, and NM profile state are stored separately.
- Restoring validates all payload hashes and parent paths before modifying files.

## Failure behavior

`main` sets `CHANGES_STARTED=1` after the backup is prepared. If a phase fails and
`--no-rollback` is not supplied, `rollback_changes` restores managed files, NM
profiles, runtime sysctl values, and service states. Installed packages remain
installed.
