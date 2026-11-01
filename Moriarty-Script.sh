#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Moriarty - OPSEC hardening for Arch Linux
# https://github.com/L1m4y/Moriarty-Script
#
# Usage: sudo bash Moriarty-Script.sh
# Requirements: Arch Linux (or derivative), systemd, NetworkManager, pacman
#
set -e
PROG="${0##*/}"
VERSION="2.0.0"
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
ok() { echo -e "  ${G}[OK]${N} $1"; }
warn() { echo -e "  ${Y}[!]${N} $1"; }
fail() { echo -e "  ${R}[FAIL]${N} $1"; exit 1; }
# snapshot a file/dir into the backup tree preserving its /etc path
bup() { local p="${1#/}"; mkdir -p "$BK/$(dirname "$p")" 2>/dev/null || true; cp -aL "$1" "$BK/$p" 2>/dev/null || true; }
[ "$EUID" -ne 0 ] && fail "sudo bash $0"
TS=$(date +%Y%m%d_%H%M%S)
BK="/root/opsec-backup.$TS"
mkdir -p "$BK"
echo -e "${B}== OPSEC MORIARTY ==${N}"
echo -e "${B}[1/8] Dependencies${N}"
pacman -S --needed --noconfirm dnscrypt-proxy bind || fail "dependency install failed (check network/mirrors)"
ok "dnscrypt-proxy + dig"
bup /etc/sysctl.conf
bup /etc/sysctl.d
echo -e "${B}[2/8] Sysctl hardening${N}"
cat > /etc/sysctl.d/99-hardening.conf << 'EOF'
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.printk = 3 3 3 3
kernel.randomize_va_space = 2
vm.mmap_rnd_bits = 32
vm.mmap_rnd_compat_bits = 16
kernel.perf_event_paranoid = 2
kernel.yama.ptrace_scope = 1
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
kernel.kexec_load_disabled = 1
kernel.sysrq = 0
dev.tty.ldisc_autoload = 0
vm.unprivileged_userfaultfd = 0
kernel.io_uring_disabled = 1
dev.tty.legacy_tiocsti = 0
kernel.panic = 1
kernel.oops_limit = 1
kernel.warn_limit = 1
fs.suid_dumpable = 0
fs.protected_fifos = 2
fs.protected_regular = 2
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
net.ipv4.ip_forward = 0
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.conf.all.arp_filter = 1
net.ipv4.conf.default.arp_filter = 1
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.all.arp_announce = 2
net.ipv4.conf.all.arp_accept = 0
net.ipv4.conf.default.arp_accept = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv6.conf.all.use_tempaddr = 2
net.ipv6.conf.default.use_tempaddr = 2
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.core.default_qdisc = fq
EOF
sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr && echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.d/99-hardening.conf || true
sysctl --system >/dev/null 2>&1 || true
ok "sysctl applied"
echo -e "${B}[3/8] Modprobe: obscure protocols and filesystems${N}"
bup /etc/modprobe.d/blacklist-obscure.conf
cat > /etc/modprobe.d/blacklist-obscure.conf << 'EOF'
install dccp /bin/false
install sctp /bin/false
install rds /bin/false
install tipc /bin/false
install n-hdlc /bin/false
install ax25 /bin/false
install netrom /bin/false
install x25 /bin/false
install rose /bin/false
install decnet /bin/false
install econet /bin/false
install af_802154 /bin/false
install ipx /bin/false
install appletalk /bin/false
install psnap /bin/false
install p8023 /bin/false
install p8022 /bin/false
install can /bin/false
install atm /bin/false
install cramfs /bin/false
install freevxfs /bin/false
install jffs2 /bin/false
install hfs /bin/false
install hfsplus /bin/false
install squashfs /bin/false
install udf /bin/false
install vivid /bin/false
EOF
ok "modprobe applied (full effect after reboot)"
echo -e "${B}[4/8] MAC per boot (systemd.link)${N}"
rm -f /etc/systemd/network/10-garbato-random-mac.link /etc/systemd/network/11-garbato-random-mac-wifi.link /etc/systemd/resolved.conf.d/garbato-dns.conf 2>/dev/null || true
cat > /etc/systemd/network/10-moriarty-random-mac.link << 'EOF'
[Match]
OriginalName=en*
[Link]
MACAddressPolicy=random
EOF
# unconditional: harmless without Wi-Fi, future-proof if a card appears later
cat > /etc/systemd/network/11-moriarty-random-mac-wifi.link << 'EOF'
[Match]
OriginalName=wl*
[Link]
MACAddressPolicy=random
EOF
ok "systemd.link ready"
echo -e "${B}[5/8] NetworkManager: MAC+IP per boot, no hostname, private IPv6${N}"
command -v nmcli >/dev/null 2>&1 || fail "NetworkManager is required"
mkdir -p /etc/NetworkManager/conf.d
bup /etc/NetworkManager/conf.d/00-mac-ip-randomize.conf
cat > /etc/NetworkManager/conf.d/00-mac-ip-randomize.conf << 'EOF'
[device]
wifi.scan-rand-mac-address=yes
[connection]
# RFC 7844-inspired per-boot identity: stable within a boot,
# new identity after every reboot (${BOOT} in the stable-id).
# Refs: NM examples/nm-conf.d/30-anon.conf, Fedora Magazine MAC randomization guide
connection.stable-id=${CONNECTION}/${BOOT}
ethernet.cloned-mac-address=stable
wifi.cloned-mac-address=stable
ipv4.dhcp-client-id=stable
ipv4.dhcp-send-hostname=false
ipv6.dhcp-send-hostname=false
ipv6.dhcp-duid=ll
ipv6.addr-gen-mode=stable-privacy
ipv6.ip6-privacy=2
EOF
bup /etc/NetworkManager/conf.d/90-dns-none.conf
printf '[main]\ndns=none\n' > /etc/NetworkManager/conf.d/90-dns-none.conf
nmcli general reload 2>/dev/null || true
nmcli -t -f NAME,TYPE connection show 2>/dev/null | grep -E ':802-3-ethernet$|:802-11-wireless$' | cut -d: -f1 | while IFS= read -r c; do
  nmcli connection modify "$c" ipv4.ignore-auto-dns yes ipv6.ignore-auto-dns yes ipv4.dns "" ipv6.dns "" 2>/dev/null || true
done
ok "NetworkManager ready"
echo -e "${B}[6/8] Swiss encrypted DNS (dnscrypt-proxy)${N}"
bup /etc/dnscrypt-proxy/dnscrypt-proxy.toml
cat > /etc/dnscrypt-proxy/dnscrypt-proxy.toml << 'EOF'
listen_addresses = ['127.0.0.1:53']
server_names = ['quad9-dnscrypt-ip4-filter-pri', 'quad9-dnscrypt-ip4-nofilter-pri', 'dns.digitale-gesellschaft.ch']
require_dnssec = true
require_nolog = true
require_nofilter = false
cache = true
cache_size = 4096
cache_min_ttl = 2400
[sources.public-resolvers]
urls = ['https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md', 'https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md']
cache_file = '/var/cache/dnscrypt-proxy/public-resolvers.md'
minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
refresh_delay = 72
EOF
mkdir -p /var/cache/dnscrypt-proxy /var/log/dnscrypt-proxy
chown dnscrypt:dnscrypt /var/cache/dnscrypt-proxy /var/log/dnscrypt-proxy 2>/dev/null || true
bup /etc/resolv.conf
rm -f /etc/resolv.conf
printf '# Generated by dnscrypt-proxy\nnameserver 127.0.0.1\noptions edns0\n' > /etc/resolv.conf
systemctl enable --now dnscrypt-proxy.service >/dev/null 2>&1 || fail "dnscrypt failed to start"
# first start may download the resolver list, so retry instead of a fixed wait
DNS_OK=""
for _ in 1 2 3 4 5; do
  sleep 2
  [ -n "$(dig example.com @127.0.0.1 +short 2>/dev/null)" ] && { DNS_OK=1; break; }
done
[ -n "$DNS_OK" ] && ok "DNS resolves" || fail "DNS broken - run: systemctl status dnscrypt-proxy"
echo -e "${B}[7/8] resolved dnscrypt-only + silent avahi + ufw${N}"
mkdir -p /etc/systemd/resolved.conf.d
if [ -f /etc/systemd/resolved.conf.d/moriarty-dns.conf ]; then bup /etc/systemd/resolved.conf.d/moriarty-dns.conf; fi
printf '[Resolve]\nDNS=127.0.0.1\nFallbackDNS=\nLLMNR=no\nMulticastDNS=no\nDNSSEC=no\n' > /etc/systemd/resolved.conf.d/moriarty-dns.conf
systemctl restart systemd-resolved 2>/dev/null || true
if [ -f /etc/avahi/avahi-daemon.conf ]; then
  bup /etc/avahi/avahi-daemon.conf
  sed -i 's/^#*disable-publishing=.*/disable-publishing=yes/' /etc/avahi/avahi-daemon.conf || true
  systemctl restart avahi-daemon 2>/dev/null || true
else
  warn "avahi not installed - skipping"
fi
if [ -f /etc/ufw/sysctl.conf ]; then
  bup /etc/ufw/sysctl.conf
  sed -i 's|^net/ipv4/conf/default/rp_filter=1|#net/ipv4/conf/default/rp_filter=1|;s|^net/ipv4/conf/all/rp_filter=1|#net/ipv4/conf/all/rp_filter=1|' /etc/ufw/sysctl.conf || true
else
  warn "ufw not installed - no active firewall"
fi
sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null 2>&1 || true
ok "resolved/avahi/ufw done"
echo -e "${B}[8/8] Verification${N}"
echo "  sysctl: kptr=$(sysctl -n kernel.kptr_restrict 2>/dev/null) dmesg=$(sysctl -n kernel.dmesg_restrict 2>/dev/null) ptrace=$(sysctl -n kernel.yama.ptrace_scope 2>/dev/null) rp=$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null) tempaddr=$(sysctl -n net.ipv6.conf.all.use_tempaddr 2>/dev/null)"
echo "  dns: $(grep nameserver /etc/resolv.conf | head -1) | dnscrypt: $(systemctl is-active dnscrypt-proxy 2>/dev/null)"
resolvectl status 2>/dev/null | grep -E "192.168.1.1|8.8.8.8|1.1.1.1" && warn "foreign DNS remains" || ok "no foreign DNS"
echo ""
echo -e "${B}COMPLETE - backup at $BK - reboot for new MAC/IP${N}"
