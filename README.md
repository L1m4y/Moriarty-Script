<br/>

<div align="center">

<img src="assets/Moriarty-Icon.png" alt="Moriarty-Script" width="192"/>

<h1>Moriarty</h1>

**One-shot OPSEC hardening for Arch Linux.**

Turn your machine into a moving target — randomized hardware identity, encrypted DNS and a locked-down kernel, in a single command.

[![OS](https://img.shields.io/badge/OS-Arch_Linux-D42F3F?logo=archlinux&logoColor=E7E7DB)](https://archlinux.org)
[![Shell](https://img.shields.io/badge/Shell-Bash-FF9700?logo=gnubash&logoColor=E7E7DB)](https://www.gnu.org/software/bash/)
[![License](https://img.shields.io/badge/License-GPL_v3-D42F3F?logo=open-source-initiative&logoColor=E7E7DB)](LICENSE)

</div>

## What it does

`Moriarty-Script.sh` runs 8 sequential phases:

| # | Phase | Description |
|:-:|-------|-------------|
| 1 | **Dependencies** | Installs `dnscrypt-proxy` and `bind` (`dig`) via pacman |
| 2 | **Kernel hardening** | 90+ hardened `sysctl` values: hides kernel pointers & dmesg, full ASLR, restricts ptrace/BPF/io_uring, hardened TCP stack, strict ARP filtering, disables `kexec`, SysRq and core dumps |
| 3 | **Module blacklist** | Disables ~25 obscure network protocols and filesystems (`dccp`, `sctp`, `x25`, `atm`, `hfs`, `cramfs`...) so they can never be loaded (note: `squashfs` included, so live ISO boots won't mount it) |
| 4 | **MAC randomization** | `systemd.link` rules giving ethernet (and Wi-Fi, if present) a **new MAC address on every boot** |
| 5 | **NetworkManager** | RFC 7844-inspired per-boot identity: MAC and DHCP identity **stable within a boot, rotating after every reboot** — no hostname leaks over DHCP, private IPv6 |
| 6 | **Encrypted DNS** | `dnscrypt-proxy` on `127.0.0.1:53` with DNSSEC-required, no-log resolvers — NetworkManager's own DNS is cut off |
| 7 | **resolved / avahi / ufw** | `systemd-resolved` queries only through dnscrypt, LLMNR & mDNS disabled, avahi publishing silenced, ufw `rp_filter` fixed |
| 8 | **Verification** | Prints kernel values, DNS status and checks for any remaining foreign DNS servers |

<details>
<summary><b>Key hardened sysctl parameters</b></summary>

```
kernel.kptr_restrict = 2          kernel.dmesg_restrict = 1
kernel.randomize_va_space = 2     kernel.yama.ptrace_scope = 1
kernel.unprivileged_bpf_disabled = 1
kernel.kexec_load_disabled = 1    kernel.sysrq = 176
kernel.io_uring_disabled = 1      fs.suid_dumpable = 0
vm.mmap_rnd_bits = 32             vm.unprivileged_userfaultfd = 0
net.ipv4.conf.all.rp_filter = 2   net.ipv6.conf.all.use_tempaddr = 2
net.ipv4.tcp_syncookies = 1       net.ipv4.tcp_rfc1337 = 1
```
*(full list in `Moriarty-Script.sh`)*

</details>

<details>
<summary><b>DNS resolvers used</b></summary>

| Resolver | Operator | Notes |
|----------|----------|-------|
| `quad9-dnscrypt-ip4-filter-pri` | Quad9 | DNSSEC, filtering, no-logging |
| `quad9-dnscrypt-ip4-nofilter-pri` | Quad9 | DNSSEC, no filtering, no-logging |
| `dns.digitale-gesellschaft.ch` | Digital Society (CH) | DNSSEC, no-logging |

Requires DNSSEC and no-logging — servers failing either check are rejected.

</details>

## Usage

```bash
git clone https://github.com/L1m4y/Moriarty-Script.git
cd Moriarty-Script
sudo bash Moriarty-Script.sh
```

> [!IMPORTANT]
> **Reboot after running** so the new randomized MAC/IP take effect.

### Requirements

- Arch Linux (or any distro using `pacman`, `NetworkManager` and `systemd`)
- Root privileges (`sudo`)
- A Wi-Fi interface optionally enables the Wi-Fi MAC rule too

## Behavior & safety

- Every file it overwrites is backed up first to `/root/opsec-backup.<timestamp>/`, preserving the original `/etc` path — every touched config is included
- DNS is verified with `dig` using automatic retries (the first dnscrypt start may download the resolver list) — if dnscrypt fails to start, the script **aborts** instead of leaving you without resolution
- The verification phase prints `sysctl` values, DNS status and warns if foreign DNS servers (router/ISP/Google/Cloudflare) are still reachable
- Settings persist across reboots; identity (MAC/IP) changes on every boot

> [!WARNING]
> The script replaces system-wide DNS and network configuration. On managed or non-standard setups (static IP, different network managers, containers/VMs), review the script before running it.

## License

Distributed under the [AGPL-3.0](LICENSE) license.

---

<div align="center">
<i>"Every fairy tale needs a good old-fashioned villain."</i><br/>
<sub>Moriarty-Script — the villain your OS deserves.</sub>
</div>
