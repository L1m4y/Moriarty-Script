#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Moriarty - OPSEC hardening for Arch Linux
# https://github.com/L1m4y/Moriarty-Script
#
# Usage: sudo bash moriarty.sh
# Requirements: Arch Linux (or derivative), systemd, NetworkManager, pacman
#
set -e
PROG="${0##*/}"
VERSION="2.0.0"

if [ -t 1 ]; then
  R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[1m'; N='\033[0m'
else
  R=''; G=''; Y=''; B=''; N=''
fi

ok() { echo -e "  ${G}[OK]${N} $1"; }
warn() { echo -e "  ${Y}[!]${N} $1" >&2; }
FAILED=0
fail() { FAILED=1; echo -e "  ${R}[FAIL]${N} $1" >&2; exit 1; }

usage() {
  cat <<EOF
$PROG $VERSION - OPSEC hardening for Arch Linux

Usage: sudo ./$PROG [options]

Options:
  -h, --help       Show this help and exit
  -V, --version    Show the version and exit
  -n, --dry-run    Show what would change without modifying the system
  -y, --yes        Do not ask for confirmation
      --no-color   Disable colored output
EOF
}

ASSUME_YES=0
USE_COLOR=1
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -V|--version) echo "$PROG $VERSION"; exit 0 ;;
    -n|--dry-run) DRY_RUN=1 ;;
    -y|--yes) ASSUME_YES=1 ;;
    --no-color) USE_COLOR=0 ;;
    *) fail "unknown option: $1 (try --help)" ;;
  esac
  shift
done

if [ "$USE_COLOR" -eq 0 ]; then
  R=''; G=''; Y=''; B=''; N=''
fi

if [ "$DRY_RUN" -ne 1 ]; then
  [ "$EUID" -ne 0 ] && fail "run as root: sudo bash $0"
fi

if [ "$ASSUME_YES" -ne 1 ] && [ "$DRY_RUN" -ne 1 ]; then
  if [ ! -t 0 ]; then
    fail "non-interactive shell: use --yes"
  fi
  echo -e "${Y}This will modify /etc and network settings.${N}"
  read -r -p "Continue? [y/N] " reply
  case "$reply" in
    [yY]|[yY][eE][sS]) ;;
    *) echo "Aborted."; exit 1 ;;
  esac
fi

TS=$(date +%Y%m%d_%H%M%S)
if [ "$DRY_RUN" -eq 1 ]; then
  BK="/root/opsec-backup.DRYRUN"
  MANIFEST=/dev/null
else
  BK="/root/opsec-backup.$TS"
  MANIFEST="$BK/MANIFEST"
  mkdir -p "$BK" || fail "cannot create backup directory $BK"
  chmod 700 "$BK"
  : > "$MANIFEST" || fail "cannot write $MANIFEST"
fi

on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    if [ "$FAILED" -eq 0 ]; then
      echo -e "  ${R}[FAIL]${N} Moriarty stopped with exit $rc" >&2
    fi
    rollback_dns
    echo "  DNS resolver files restored" >&2
    echo "  Backup: ${BK:-none}" >&2
    echo "  Full restore: sudo ./moriarty-restore.sh ${BK:-<backup-dir>}" >&2
  fi
}
trap on_exit EXIT

# Run a state-changing command, or print it in dry-run mode.
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  [dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

# Back up a path preserving symlinks. Record whether it existed so the
# restore script can remove files that Moriarty created.
backup_path() {
  local src=$1 rel=${1#/}
  [ "$DRY_RUN" -eq 1 ] && return 0
  if grep -qxF "modified $src" "$MANIFEST" 2>/dev/null ||
     grep -qxF "created $src" "$MANIFEST" 2>/dev/null; then
    return 0
  fi
  if [ -e "$src" ] || [ -L "$src" ]; then
    mkdir -p "$BK/$(dirname "$rel")" || fail "cannot create backup directory for $src"
    cp -a "$src" "$BK/$rel" || fail "cannot back up $src"
    printf 'modified %s\n' "$src" >> "$MANIFEST"
  else
    printf 'created %s\n' "$src" >> "$MANIFEST"
  fi
}

# Write a file atomically, after backing it up. Reads the new content
# from stdin so callers can keep using heredocs.
write_file() {
  local dest=$1 tmp
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  [dry-run] would write %s\n' "$dest"
    cat >/dev/null
    return 0
  fi
  backup_path "$dest"
  mkdir -p "$(dirname "$dest")" || fail "cannot create directory for $dest"
  tmp="${dest}.moriarty.$$"
  cat > "$tmp" || { rm -f "$tmp"; fail "cannot write $dest"; }
  chmod 644 "$tmp"
  mv -f "$tmp" "$dest" || { rm -f "$tmp"; fail "cannot install $dest"; }
}

bup() { backup_path "$1"; }

# Put a single path back from the backup tree, or remove it if Moriarty
# created it. Used by the failure rollback below.
restore_path() {
  local src=$1 rel=${1#/}
  if grep -qxF "modified $src" "$MANIFEST" 2>/dev/null; then
    cp -a "$BK/$rel" "$src" 2>/dev/null || return 1
  elif grep -qxF "created $src" "$MANIFEST" 2>/dev/null; then
    rm -f "$src" 2>/dev/null || return 1
  fi
}

# If the script dies after resolv.conf and NetworkManager have been
# repointed at a dnscrypt instance that never came up, the machine is left
# without DNS. Undo the two files that cause that, nothing else.
rollback_dns() {
  [ -n "${BK:-}" ] && [ -d "$BK" ] || return 0
  restore_path /etc/resolv.conf
  restore_path /etc/NetworkManager/conf.d/90-dns-none.conf
  systemctl --quiet restart NetworkManager >/dev/null 2>&1 || true
  if command -v resolvectl >/dev/null 2>&1; then
    systemctl --quiet restart systemd-resolved >/dev/null 2>&1 || true
  fi
}

# Rewrite a key in ufw's sysctl file, appending it when absent.
ufw_sysctl() {
  local key=$1 val=$2 file=/etc/ufw/sysctl.conf
  if grep -qE "^#?${key}=" "$file"; then
    sed -i -E "s|^#?${key}=.*|${key}=${val}|" "$file"
  else
    printf '%s=%s\n' "$key" "$val" >> "$file"
  fi
}

echo -e "${B}== OPSEC MORIARTY ==${N}"
echo -e "${B}[1/7] Dependencies${N}"
run pacman -S --needed --noconfirm dnscrypt-proxy bind || fail "dependency install failed (check network/mirrors)"
ok "dnscrypt-proxy + dig"
bup /etc/sysctl.conf
bup /etc/sysctl.d
echo -e "${B}[2/7] Sysctl hardening${N}"
# Only values that the kernel does not already ship as defaults and that
# systemd's 50-default.conf does not apply (rp_filter, accept_source_route,
# protected_{hardlinks,symlinks}). Throughput knobs live in 99-performance.conf.
write_file /etc/sysctl.d/99-hardening.conf << 'EOF'
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.printk = 3 3 3 3
vm.mmap_rnd_bits = 32
vm.mmap_rnd_compat_bits = 16
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
kernel.kexec_load_disabled = 1
kernel.sysrq = 0
dev.tty.ldisc_autoload = 0
vm.unprivileged_userfaultfd = 0
kernel.io_uring_disabled = 1
dev.tty.legacy_tiocsti = 0
# Reboot 30s after a kernel oops so the backtrace reaches the journal.
# Do not set warn_limit=1: it is panic_on_warn and a benign WARN in a
# driver would turn into a reboot loop.
kernel.oops_limit = 1
kernel.panic = 30
fs.protected_fifos = 2
fs.protected_regular = 2
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.conf.all.arp_filter = 1
net.ipv4.conf.default.arp_filter = 1
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.all.arp_announce = 2
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_rfc1337 = 1
net.ipv6.conf.all.use_tempaddr = 2
net.ipv6.conf.default.use_tempaddr = 2
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
EOF
write_file /etc/sysctl.d/99-performance.conf << 'EOF'
# Throughput tuning, not hardening. Remove this file if you do not want it.
net.core.default_qdisc = fq
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_slow_start_after_idle = 0
EOF
if [ "$DRY_RUN" -eq 1 ]; then
  printf '  [dry-run] would enable BBR if available\n'
elif sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
  echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.d/99-performance.conf
fi
if [ "$DRY_RUN" -eq 1 ]; then
  printf '  [dry-run] sysctl --system\n'
else
  sysctl --system >/dev/null 2>&1 || true
fi
ok "sysctl applied"
echo -e "${B}[3/7] Modprobe: obscure protocols and filesystems${N}"
bup /etc/modprobe.d/blacklist-obscure.conf
write_file /etc/modprobe.d/blacklist-obscure.conf << 'EOF'
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
echo -e "${B}[4/7] NetworkManager: identity per boot${N}"
# NetworkManager already randomizes MACs at activation. Writing systemd.link
# rules on top of it duplicated the job and made the effective policy depend
# on which layer won, so only the NM profile remains. Remove the .link files
# written by Moriarty 1.x if they are still around.
run rm -f /etc/systemd/network/10-moriarty-random-mac.link \
          /etc/systemd/network/11-moriarty-random-mac-wifi.link
command -v nmcli >/dev/null 2>&1 || fail "NetworkManager is required"
run mkdir -p /etc/NetworkManager/conf.d
bup /etc/NetworkManager/conf.d/00-mac-ip-randomize.conf
write_file /etc/NetworkManager/conf.d/00-mac-ip-randomize.conf << 'EOF'
[connection]
# Identity is stable inside a boot and rotates on reboot: ${BOOT} changes
# every boot and the MAC, DHCP client-id and DUID are derived from it.
connection.stable-id=${CONNECTION}/${BOOT}
ethernet.cloned-mac-address=stable
wifi.cloned-mac-address=stable
ipv4.dhcp-client-id=stable
ipv4.dhcp-send-hostname=false
ipv6.dhcp-send-hostname=false
ipv6.dhcp-duid=ll
ipv6.addr-gen-mode=stable-privacy
EOF
bup /etc/NetworkManager/conf.d/90-dns-none.conf
printf '[main]\ndns=none\n' | write_file /etc/NetworkManager/conf.d/90-dns-none.conf
run nmcli general reload 2>/dev/null || true
nmcli -t -f NAME,TYPE connection show 2>/dev/null | grep -E ':802-3-ethernet$|:802-11-wireless$' | cut -d: -f1 | while IFS= read -r c; do
  run nmcli connection modify "$c" ipv4.ignore-auto-dns yes ipv6.ignore-auto-dns yes ipv4.dns "" ipv6.dns "" 2>/dev/null || true
done
ok "NetworkManager ready"
echo -e "${B}[5/7] Encrypted DNS (dnscrypt-proxy)${N}"
bup /etc/dnscrypt-proxy/dnscrypt-proxy.toml
write_file /etc/dnscrypt-proxy/dnscrypt-proxy.toml << 'EOF'
listen_addresses = ['127.0.0.1:53']
server_names = ['quad9-dnscrypt-ip4-nofilter-pri', 'dns.digitale-gesellschaft.ch']
require_dnssec = true
require_nolog = true
require_nofilter = true
cache = true
cache_size = 4096
cache_min_ttl = 2400
# The resolver list is fetched before dnscrypt can answer anything, so it
# needs a bootstrap resolver. Point it at Quad9 instead of Google's
# hardcoded default and forbid falling back to the system resolver, which
# by then is dnscrypt itself.
bootstrap_resolvers = ['9.9.9.9:53', '149.112.112.112:53']
ignore_system_dns = true
[sources.public-resolvers]
urls = ['https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md', 'https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md']
cache_file = '/var/cache/dnscrypt-proxy/public-resolvers.md'
minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
refresh_delay = 72
EOF
# The packaged unit runs with DynamicUser= and CacheDirectory=dnscrypt-proxy,
# so the cache directory is created and owned by systemd. Creating it here
# as root, or chowning it to a dnscrypt user that does not exist, breaks it.
bup /etc/resolv.conf
printf '# Generated by dnscrypt-proxy\nnameserver 127.0.0.1\noptions edns0\n' | write_file /etc/resolv.conf
# The packaged .socket owns port 53 and ignores listen_addresses, so it
# has to stay out of the way of the service that reads our config.
if [ "$DRY_RUN" -eq 1 ]; then
  printf '  [dry-run] systemctl disable --now dnscrypt-proxy.socket\n'
else
  systemctl disable --now dnscrypt-proxy.socket >/dev/null 2>&1 || true
fi
if [ "$DRY_RUN" -eq 0 ]; then
  dnscrypt-proxy -check -config /etc/dnscrypt-proxy/dnscrypt-proxy.toml >/dev/null 2>&1 \
    || fail "dnscrypt-proxy rejected /etc/dnscrypt-proxy/dnscrypt-proxy.toml"
fi
# enable --now is a no-op when the unit is already running, so an
# existing install would keep the old config. Restart explicitly.
run systemctl --quiet enable dnscrypt-proxy.service || fail "could not enable dnscrypt-proxy"
run systemctl --quiet restart dnscrypt-proxy.service || fail "dnscrypt failed to restart"
# first start may download the resolver list, so retry instead of a fixed wait
if [ "$DRY_RUN" -eq 1 ]; then
  ok "dry-run: skipping DNS wait"
else
  DNS_OK=""
  for _ in 1 2 3 4 5; do
    sleep 2
    [ -n "$(dig example.com @127.0.0.1 +short 2>/dev/null)" ] && { DNS_OK=1; break; }
  done
  [ -n "$DNS_OK" ] && ok "DNS resolves" || fail "DNS broken - run: systemctl status dnscrypt-proxy"
fi
echo -e "${B}[6/7] resolved dnscrypt-only + silent avahi + ufw${N}"
run mkdir -p /etc/systemd/resolved.conf.d
if [ -f /etc/systemd/resolved.conf.d/moriarty-dns.conf ]; then bup /etc/systemd/resolved.conf.d/moriarty-dns.conf; fi
printf '[Resolve]\nDNS=127.0.0.1\nFallbackDNS=\nLLMNR=no\nMulticastDNS=no\nDNSSEC=no\n' | write_file /etc/systemd/resolved.conf.d/moriarty-dns.conf
run systemctl restart systemd-resolved 2>/dev/null || true
if [ -f /etc/avahi/avahi-daemon.conf ]; then
  bup /etc/avahi/avahi-daemon.conf
  run sed -i 's/^#*disable-publishing=.*/disable-publishing=yes/' /etc/avahi/avahi-daemon.conf || true
  run systemctl restart avahi-daemon 2>/dev/null || true
else
  warn "avahi not installed - skipping"
fi
if [ -f /etc/ufw/sysctl.conf ]; then
  bup /etc/ufw/sysctl.conf
  # ufw loads this file after /etc/sysctl.d, so the values we care about
  # have to be mirrored here or ufw silently wins.
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  [dry-run] would align /etc/ufw/sysctl.conf with 99-hardening.conf\n'
  else
    ufw_sysctl net/ipv4/conf/all/rp_filter 2
    ufw_sysctl net/ipv4/conf/default/rp_filter 2
    ufw_sysctl net/ipv4/conf/all/log_martians 1
    ufw_sysctl net/ipv4/conf/default/log_martians 1
  fi
else
  warn "ufw not installed - no active firewall"
fi
ok "resolved/avahi/ufw done"
echo -e "${B}[7/7] Verification${N}"
if [ "$DRY_RUN" -eq 1 ]; then
  ok "dry-run: nothing to verify"
else
  echo "  sysctl: kptr=$(sysctl -n kernel.kptr_restrict 2>/dev/null) dmesg=$(sysctl -n kernel.dmesg_restrict 2>/dev/null) ptrace=$(sysctl -n kernel.yama.ptrace_scope 2>/dev/null) tempaddr=$(sysctl -n net.ipv6.conf.all.use_tempaddr 2>/dev/null)"
  systemctl is-active --quiet dnscrypt-proxy && ok "dnscrypt-proxy active" \
    || warn "dnscrypt-proxy is not active"

  # Query the way applications do: through /etc/resolv.conf, not by
  # pointing dig straight at 127.0.0.1, which bypasses resolved and NM.
  if [ -n "$(dig +short +time=3 +tries=1 example.com 2>/dev/null)" ]; then
    ok "system resolver answers"
  else
    warn "system resolver does not answer"
  fi

  # Any DNS server left in resolvectl that is not the local proxy is an
  # upstream resolver the queries can leak to. Parse the field instead of
  # matching a hardcoded list of addresses.
  FOREIGN=""
  if command -v resolvectl >/dev/null 2>&1; then
    FOREIGN=$(resolvectl status 2>/dev/null \
      | sed -n 's/.*DNS Servers: //p; s/.*Current DNS Server: //p' \
      | tr ' ' '\n' | grep -vE '^(127\.0\.0\.1|::1|)$' || true)
  fi
  if [ -n "$FOREIGN" ]; then
    warn "upstream resolvers still configured: $(echo "$FOREIGN" | tr '\n' ' ')"
  else
    ok "no upstream resolver configured"
  fi
fi
echo ""
echo -e "${B}COMPLETE - backup at $BK - reboot to activate the new identity${N}"
