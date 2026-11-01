<br/>

<div align="center">

<img src="assets/Moriarty-Icon.png" alt="Moriarty" width="192"/>

<h1>Moriarty</h1>

**One-shot OPSEC hardening for Arch Linux.**

A single-command configuration profile: per-boot hardware identity, encrypted DNS and a tightened kernel.

[![OS](https://img.shields.io/badge/OS-Arch_Linux-1793D1?logo=archlinux&logoColor=E7E7DB)](https://archlinux.org)
[![Shell](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnubash&logoColor=FFFFFF)](https://www.gnu.org/software/bash/)
[![License](https://img.shields.io/badge/License-GPL_3.0-3DA639?logo=open-source-initiative&logoColor=FFFFFF)](LICENSE)

</div>

## What it does

`moriarty.sh` runs 7 sequential phases:

| # | Phase | Description |
|:-:|-------|-------------|
| 1 | **Dependencies** | Installs `dnscrypt-proxy` and `bind` (for `dig`) via pacman |
| 2 | **Sysctl hardening** | 38 kernel/network tunables: hides kernel pointers and dmesg, ASLR, ptrace/BPF/io_uring limits, ICMP and redirect controls, disabled SysRq, core dumps. Values already provided by the kernel or `systemd` (like `rp_filter=2` and `protected_{hardlinks,symlinks}`) are not repeated |
| 3 | **Module blacklist** | Disables 27 obscure protocols and filesystems (`dccp`, `sctp`, `x25`, `atm`, `hfs`, `cramfs`, `squashfs`...) through `install ... /bin/false`. Built-in modules and manual `insmod` are not covered; `squashfs` is included, so Live ISO / install media will not mount unless the module is available |
| 4 | **Identity per boot** | NetworkManager derives MAC, DHCP client-id, DHCPv6 DUID and IPv6 interface-ID from one per-boot `stable-id`: identity is stable while a boot lasts and rotates after every reboot. No hostname is sent over DHCP and IPv6 privacy extensions are enabled |
| 5 | **Encrypted DNS** | `dnscrypt-proxy` on `127.0.0.1:53`, DNSSEC- and no-log-required, DNS-filtering disabled. NM's own DNS is switched off so queries cannot leak through it |
| 6 | **resolved / avahi / ufw** | `systemd-resolved` forwards only to dnscrypt; LLMNR and mDNS off; Avahi publishing silenced; UFW `sysctl` file aligned with the profile because it otherwise overrides `/etc/sysctl.d` |
| 7 | **Verification** | Kernel values, dnscrypt state, a real lookup through `/etc/resolv.conf`, and detection of any upstream DNS server still configured in `systemd-resolved` |

<details>
<summary><b>Representative sysctl parameters</b></summary>

```text
kernel.kptr_restrict = 2          kernel.dmesg_restrict = 1
kernel.unprivileged_bpf_disabled = 1
kernel.kexec_load_disabled = 1    kernel.sysrq = 0
kernel.io_uring_disabled = 1      fs.suid_dumpable = 0
kernel.oops_limit = 1             kernel.panic = 30
fs.protected_fifos = 2           fs.protected_regular = 2
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.all.arp_ignore = 1   net.ipv4.conf.all.arp_announce = 2
net.ipv6.conf.all.use_tempaddr = 2
```

Full list in `moriarty.sh`.

</details>

<details>
<summary><b>DNS resolvers used</b></summary>

| Resolver | Operator | Notes |
|----------|----------|-------|
| `quad9-dnscrypt-ip4-nofilter-pri` | Quad9 | DNSSEC, no filtering, no-logging |
| `dns.digitale-gesellschaft.ch` | Digital Society (CH) | DNSSEC, no-logging |
| bootstrap: `9.9.9.9` | Quad9 | plaintext, only to fetch the resolver list |

Requires DNSSEC and no logging; servers failing either check are rejected. The bootstrap query is sent in clear text because the resolver list has to be fetched before dnscrypt can answer.

</details>

## Usage

```bash
git clone https://github.com/L1m4y/Moriarty-Script.git
cd Moriarty-Script
sudo bash moriarty.sh            # apply
sudo bash moriarty.sh --dry-run # show what would change first
```

Undo any apply:

```bash
sudo ./moriarty-restore.sh /root/opsec-backup.<timestamp>
```

> [!IMPORTANT]
> **Reboot after running** so the new identity (MAC, DHCP client-id) takes effect.

### Requirements

- Arch Linux or a compatible derivative (`pacman`, `systemd`, `NetworkManager`)
- Root privileges (`sudo`)
- `dig` comes from the `bind` package, installed by phase 1 if missing

### Script options

```text
-h, --help                  Show help
-V, --version                Show version
-n, --dry-run                Print actions without changing the system
-y, --yes                    Skip the confirmation prompt
--no-color                  Disable colored output
```

## Behavior & safety

- Every file overwritten is backed up first to `/root/opsec-backup.<timestamp>/`, preserving its path inside `/etc`; the manifest drives `moriarty-restore.sh`.
- If a phase fails after `/etc/resolv.conf` and the NetworkManager DNS file have been repointed at dnscrypt, both are restored before exit, so a failed run does not leave the machine without a working resolver.
- dnscrypt configuration is validated with `dnscrypt-proxy --check` before the service is enabled; a broken config aborts instead of starting a dead proxy.
- Verification queries the real system path (`/etc/resolv.conf`) and reports `systemd-resolved` upstreams different from `127.0.0.1` or `::1`, instead of scanning a hard-coded list of addresses.
- Spare `systemd.link` rules created by older Moriarty versions are removed, so only the NetworkManager identity layer remains.
- Settings persist across reboots. The MAC and DHCP identity change after every reboot; the assigned IP address is still chosen by the DHCP server.

> [!WARNING]
> The script replaces system-wide DNS and network configuration. Review before running on managed systems, containers, VMs, static-IP deployments, or machines using 802.1X or captive portals. Encrypted DNS hides the resolver from the network, not the destination: the TCP connections and, in most cases, the HTTPS SNI remain visible. This is not an anonymity tool.

## License

Distributed under the [GPL-3.0](LICENSE) license.

