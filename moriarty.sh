#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Moriarty - host privacy/hardening profile for Arch Linux and derivatives.
# Requires: systemd, NetworkManager, pacman, dnscrypt-proxy (installed by script), bind (dig).

set -Eeuo pipefail
IFS=$'\n\t'

PROG=${0##*/}
VERSION='2.1.0'
DRY_RUN=0
ASSUME_YES=0
USE_COLOR=1
BACKUP_DIR=''
MANIFEST=''
DNS_SWITCHED=0
LOCK_FILE='/run/lock/moriarty.lock'

if [[ -t 1 ]]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BOLD=''; RESET=''
fi

log()  { printf '%s\n' "$*"; }
ok()   { printf '  %s[OK]%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '  %s[!]%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()  { printf '  %s[FAIL]%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
$PROG $VERSION - privacy and host hardening for Arch Linux

Usage: sudo ./$PROG [options]

Options:
  -h, --help       Show this help and exit
  -V, --version    Show version and exit
  -n, --dry-run    Show planned operations without changing the system
  -y, --yes        Do not ask for confirmation
      --no-color   Disable colored output

A root-owned backup is created in /root/moriarty-backup.*.
Restore with: sudo ./moriarty-restore.sh [backup-directory]
EOF
}

while (($#)); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -V|--version) printf '%s %s\n' "$PROG" "$VERSION"; exit 0 ;;
    -n|--dry-run) DRY_RUN=1 ;;
    -y|--yes) ASSUME_YES=1 ;;
    --no-color) USE_COLOR=0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

if ((USE_COLOR == 0)); then RED=''; GREEN=''; YELLOW=''; BOLD=''; RESET=''; fi

run() {
  if ((DRY_RUN)); then
    printf '  [dry-run]'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# Paths handled by this program are intentionally explicit. The restore tool
# has the same allow-list; a backup manifest can never select arbitrary paths.
manifest_has() {
  local action=$1 path=$2 entry
  printf -v entry '%s\t%s' "$action" "$path"
  [[ -f "$MANIFEST" ]] && grep -Fqx -- "$entry" "$MANIFEST"
}

backup_path() {
  local source=$1 relative target
  ((DRY_RUN)) && return 0
  relative=${source#/}
  if manifest_has modified "$source" || manifest_has created "$source"; then
    return 0
  fi
  target="$BACKUP_DIR/$relative"
  if [[ -e "$source" || -L "$source" ]]; then
    install -d -m 0700 -- "$(dirname "$target")"
    cp -aT -- "$source" "$target" || die "could not back up $source"
    printf 'modified\t%s\n' "$source" >> "$MANIFEST"
  else
    printf 'created\t%s\n' "$source" >> "$MANIFEST"
  fi
}

write_file() {
  local destination=$1 directory temporary
  directory=$(dirname "$destination")
  if ((DRY_RUN)); then
    printf '  [dry-run] would replace %s\n' "$destination"
    cat >/dev/null
    return 0
  fi
  backup_path "$destination"
  install -d -m 0755 -- "$directory"
  temporary=$(mktemp "$directory/.${destination##*/}.moriarty.XXXXXX") || die "cannot create temporary file for $destination"
  if ! cat > "$temporary"; then
    rm -f -- "$temporary"
    die "cannot write temporary file for $destination"
  fi
  chmod 0644 "$temporary"
  if ! mv -fT -- "$temporary" "$destination"; then
    rm -f -- "$temporary"
    die "cannot install $destination"
  fi
}

restore_one_path() {
  local path=$1 relative saved
  ((DRY_RUN)) && { printf '  [dry-run] rollback %s\n' "$path"; return 0; }
  relative=${path#/}
  saved="$BACKUP_DIR/$relative"
  if manifest_has modified "$path"; then
    [[ -e "$saved" || -L "$saved" ]] || return 1
    install -d -m 0755 -- "$(dirname "$path")"
    cp -aT -- "$saved" "$path"
  elif manifest_has created "$path"; then
    rm -f -- "$path"
  fi
}

rollback_dns_files() {
  ((DRY_RUN || DNS_SWITCHED == 0)) && return 0
  [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]] || return 0
  warn 'DNS setup failed after the resolver switch; restoring resolver routing files.'
  restore_one_path /etc/resolv.conf || true
  restore_one_path /etc/NetworkManager/conf.d/90-dns-none.conf || true
  restore_one_path /etc/systemd/resolved.conf.d/moriarty-dns.conf || true
  systemctl try-restart NetworkManager >/dev/null 2>&1 || true
  systemctl try-restart systemd-resolved >/dev/null 2>&1 || true
}

on_exit() {
  local status=$?
  if ((status != 0)); then
    rollback_dns_files
    if [[ -n "$BACKUP_DIR" ]]; then
      printf '\nBackup retained at: %s\n' "$BACKUP_DIR" >&2
      printf 'Full restore: sudo ./moriarty-restore.sh %q\n' "$BACKUP_DIR" >&2
    fi
  fi
  exit "$status"
}
trap on_exit EXIT

capture_sysctl_state() {
  local key value encoded
  local -a keys=(
    kernel.kptr_restrict kernel.dmesg_restrict kernel.printk
    vm.mmap_rnd_bits vm.mmap_rnd_compat_bits net.core.bpf_jit_harden
    kernel.sysrq dev.tty.ldisc_autoload vm.unprivileged_userfaultfd
    dev.tty.legacy_tiocsti fs.protected_fifos fs.protected_regular
    net.ipv4.conf.all.accept_redirects net.ipv4.conf.default.accept_redirects
    net.ipv4.conf.all.secure_redirects net.ipv4.conf.default.secure_redirects
    net.ipv4.conf.all.send_redirects net.ipv4.conf.default.send_redirects
    net.ipv6.conf.all.accept_source_route net.ipv6.conf.default.accept_source_route
    net.ipv4.conf.all.log_martians net.ipv4.conf.default.log_martians
    net.ipv4.conf.all.arp_filter net.ipv4.conf.default.arp_filter
    net.ipv4.conf.all.arp_ignore net.ipv4.conf.all.arp_announce
    net.ipv4.tcp_synack_retries net.ipv4.tcp_rfc1337
    net.ipv6.conf.all.use_tempaddr net.ipv6.conf.default.use_tempaddr
    net.ipv6.conf.all.accept_redirects net.ipv6.conf.default.accept_redirects
    net.core.default_qdisc net.ipv4.tcp_max_syn_backlog
    net.ipv4.tcp_slow_start_after_idle net.ipv4.tcp_congestion_control
    net.ipv4.conf.all.rp_filter net.ipv4.conf.default.rp_filter
  )
  : > "$BACKUP_DIR/sysctl-runtime.tsv"
  chmod 0600 "$BACKUP_DIR/sysctl-runtime.tsv"
  for key in "${keys[@]}"; do
    if value=$(sysctl -n "$key" 2>/dev/null); then
      encoded=$(printf '%s' "$value" | base64 -w0)
      printf '%s\t%s\n' "$key" "$encoded" >> "$BACKUP_DIR/sysctl-runtime.tsv"
    fi
  done
}

capture_service_state() {
  local unit enabled active
  local -a units=(
    dnscrypt-proxy.service dnscrypt-proxy.socket
    NetworkManager.service systemd-resolved.service avahi-daemon.service
  )
  : > "$BACKUP_DIR/systemd-units.tsv"
  chmod 0600 "$BACKUP_DIR/systemd-units.tsv"
  for unit in "${units[@]}"; do
    enabled=$(systemctl is-enabled "$unit" 2>/dev/null || true)
    active=$(systemctl is-active "$unit" 2>/dev/null || true)
    [[ -n "$enabled" ]] || enabled=not-found
    [[ -n "$active" ]] || active=inactive
    printf '%s\t%s\t%s\n' "$unit" "$enabled" "$active" >> "$BACKUP_DIR/systemd-units.tsv"
  done
}

base64_encode() { printf '%s' "$1" | base64 -w0; }

capture_networkmanager_profiles() {
  local listing uuid type dns4 ignore4 dns6 ignore6
  [[ -f "$BACKUP_DIR/networkmanager-profiles.tsv" ]] && return 0
  : > "$BACKUP_DIR/networkmanager-profiles.tsv"
  chmod 0600 "$BACKUP_DIR/networkmanager-profiles.tsv"
  listing=$(nmcli -t -f UUID,TYPE connection show 2>/dev/null) || die 'cannot enumerate NetworkManager profiles'
  while IFS=: read -r uuid type; do
    [[ "$type" == '802-3-ethernet' || "$type" == '802-11-wireless' ]] || continue
    [[ "$uuid" =~ ^[0-9a-fA-F-]{36}$ ]] || continue
    dns4=$(nmcli -g ipv4.dns connection show "$uuid" 2>/dev/null || true)
    ignore4=$(nmcli -g ipv4.ignore-auto-dns connection show "$uuid" 2>/dev/null || true)
    dns6=$(nmcli -g ipv6.dns connection show "$uuid" 2>/dev/null || true)
    ignore6=$(nmcli -g ipv6.ignore-auto-dns connection show "$uuid" 2>/dev/null || true)
    printf '%s|%s|%s|%s|%s\n' \
      "$uuid" "$(base64_encode "$dns4")" "$(base64_encode "$ignore4")" \
      "$(base64_encode "$dns6")" "$(base64_encode "$ignore6")" \
      >> "$BACKUP_DIR/networkmanager-profiles.tsv"
  done <<< "$listing"
}

set_ufw_sysctl() {
  local key=$1 value=$2 file=/etc/ufw/sysctl.conf temporary
  local output
  [[ -f "$file" ]] || return 0
  backup_path "$file"
  temporary=$(mktemp /etc/ufw/.sysctl.conf.moriarty.XXXXXX) || die 'cannot create UFW sysctl temporary file'
  output=$(awk -v key="$key" -v value="$value" '
    BEGIN { prefix=key "="; found=0 }
    {
      line=$0
      normalized=line
      sub(/^[[:space:]]*#[[:space:]]*/, "", normalized)
      sub(/^[[:space:]]*/, "", normalized)
      if (index(normalized, prefix) == 1) {
        if (!found) print key "=" value
        found=1
      } else {
        print line
      }
    }
    END { if (!found) print key "=" value }
  ' "$file") || { rm -f -- "$temporary"; die 'cannot update UFW sysctl settings'; }
  printf '%s\n' "$output" > "$temporary"
  chmod --reference="$file" "$temporary"
  chown --reference="$file" "$temporary"
  mv -fT -- "$temporary" "$file"
}

set_avahi_publishing_off() {
  local file=/etc/avahi/avahi-daemon.conf temporary
  [[ -f "$file" ]] || { warn 'Avahi is not installed; skipping its configuration'; return 0; }
  backup_path "$file"
  temporary=$(mktemp /etc/avahi/.avahi-daemon.conf.moriarty.XXXXXX) || die 'cannot create Avahi temporary file'
  awk '
    BEGIN { in_server=0; server_seen=0; key_seen=0 }
    /^\[[^]]+\][[:space:]]*$/ {
      if (in_server && !key_seen) { print "disable-publishing=yes"; key_seen=1 }
      in_server=($0 == "[server]")
      if (in_server) server_seen=1
      print
      next
    }
    {
      if (in_server && $0 ~ /^[[:space:]]*#?[[:space:]]*disable-publishing[[:space:]]*=/) {
        if (!key_seen) print "disable-publishing=yes"
        key_seen=1
        next
      }
      print
    }
    END {
      if (in_server && !key_seen) print "disable-publishing=yes"
      if (!server_seen) print "\n[server]\ndisable-publishing=yes"
    }
  ' "$file" > "$temporary" || { rm -f -- "$temporary"; die 'cannot update Avahi configuration'; }
  chmod --reference="$file" "$temporary"
  chown --reference="$file" "$temporary"
  mv -fT -- "$temporary" "$file"
}

printf '%s%s== MORIARTY %s ==%s\n' "$BOLD" '' "$VERSION" "$RESET"

if ((DRY_RUN)); then
  log '[1/7] Dependencies: would install dnscrypt-proxy and bind with pacman.'
  log '[2/7] Sysctl: would save current values and install reversible hardening/performance profiles.'
  log '[3/7] Modprobe: would configure the optional protocol/filesystem blacklist.'
  log '[4/7] NetworkManager: would set per-boot stable identity and disable profile-provided DNS.'
  log '[5/7] DNSCrypt: would configure, validate, start and test the local resolver.'
  log '[6/7] resolved/Avahi/UFW: would apply the corresponding configuration where present.'
  log '[7/7] Verification: would test the system resolver and DNSCrypt endpoint.'
  exit 0
fi

((EUID == 0)) || die "run as root: sudo bash $PROG"
[[ -r /etc/os-release ]] || die '/etc/os-release is missing'
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == arch ]] || [[ " ${ID_LIKE:-} " == *"arch"* ]] || warn "This is not a detected Arch Linux system; continuing at your own risk."

for cmd in pacman systemctl sysctl nmcli base64 flock realpath stat mktemp; do require_command "$cmd"; done

if ((ASSUME_YES == 0)); then
  [[ -t 0 ]] || die 'non-interactive shell: use --yes'
  printf '%sThis modifies /etc, kernel settings, NetworkManager and DNS.%s\n' "$YELLOW" "$RESET"
  read -r -p 'Continue? [y/N] ' answer
  [[ "$answer" =~ ^([yY]|[yY][eE][sS])$ ]] || { log 'Aborted.'; exit 1; }
fi

install -d -m 0755 /run/lock
exec 9>"$LOCK_FILE"
flock -n 9 || die 'another Moriarty process is already running'

BACKUP_DIR=$(mktemp -d /root/moriarty-backup.XXXXXXXX) || die 'cannot create backup directory'
chmod 0700 "$BACKUP_DIR"
MANIFEST="$BACKUP_DIR/MANIFEST"
: > "$MANIFEST"
chmod 0600 "$MANIFEST"

capture_sysctl_state
capture_service_state
capture_networkmanager_profiles

log '[1/7] Installing dependencies'
pacman -S --needed --noconfirm dnscrypt-proxy bind || die 'dependency installation failed; check network and pacman mirrors'
require_command dig
ok 'dnscrypt-proxy and bind are installed'

log '[2/7] Applying sysctl hardening and performance profiles'
write_file /etc/sysctl.d/99-hardening.conf <<'EOF'
# Moriarty: reversible hardening profile.
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.printk = 3 3 3 3
vm.mmap_rnd_bits = 32
vm.mmap_rnd_compat_bits = 16
net.core.bpf_jit_harden = 2
kernel.sysrq = 0
dev.tty.ldisc_autoload = 0
vm.unprivileged_userfaultfd = 0
dev.tty.legacy_tiocsti = 0
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

write_file /etc/sysctl.d/99-performance.conf <<'EOF'
# Moriarty: performance tuning, separate from security policy.
net.core.default_qdisc = fq
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_slow_start_after_idle = 0
EOF

if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
  printf '\nnet.ipv4.tcp_congestion_control = bbr\n' >> /etc/sysctl.d/99-performance.conf
else
  warn 'BBR is not available in this kernel; leaving congestion control unchanged.'
fi

SYSCTL_LOG=$(mktemp /run/moriarty-sysctl.XXXXXX)
if ! sysctl --system >"$SYSCTL_LOG" 2>&1; then
  cat "$SYSCTL_LOG" >&2
  rm -f "$SYSCTL_LOG"
  die 'sysctl --system failed'
fi
if grep -qiE 'cannot stat|permission denied|invalid argument|unknown key|error:' "$SYSCTL_LOG"; then
  cat "$SYSCTL_LOG" >&2
  rm -f "$SYSCTL_LOG"
  die 'one or more sysctl settings could not be applied'
fi
rm -f "$SYSCTL_LOG"
ok 'sysctl profiles applied'

log '[3/7] Configuring optional module blacklist'
write_file /etc/modprobe.d/blacklist-obscure.conf <<'EOF'
# Moriarty: prevents normal modprobe loading of rarely used protocols/filesystems.
# This does not unload modules already in use or block built-in kernel features.
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
ok 'modprobe policy written (full effect may require reboot)'

log '[4/7] Configuring NetworkManager identity policy'
command -v nmcli >/dev/null 2>&1 || die 'NetworkManager (nmcli) is required'
write_file /etc/NetworkManager/conf.d/00-mac-ip-randomize.conf <<'EOF'
[connection]
# Stable during one boot; changes when NetworkManager creates a new boot ID.
connection.stable-id=${CONNECTION}/${BOOT}
ethernet.cloned-mac-address=stable
wifi.cloned-mac-address=stable
ipv4.dhcp-client-id=stable
ipv4.dhcp-send-hostname=false
ipv6.dhcp-send-hostname=false
ipv6.dhcp-duid=ll
ipv6.addr-gen-mode=stable-privacy
EOF
write_file /etc/NetworkManager/conf.d/90-dns-none.conf <<'EOF'
[main]
dns=none
EOF

# Profile values were saved before any changes, using UUIDs and base64 fields.
while IFS=$'\t' read -r uuid type; do
  [[ "$type" == '802-3-ethernet' || "$type" == '802-11-wireless' ]] || continue
  [[ "$uuid" =~ ^[0-9a-fA-F-]{36}$ ]] || continue
  if ! nmcli connection modify "$uuid" \
      ipv4.ignore-auto-dns yes ipv6.ignore-auto-dns yes \
      ipv4.dns '' ipv6.dns ''; then
    warn "could not clear per-profile DNS settings for connection $uuid"
  fi
done < <(nmcli -t -f UUID,TYPE connection show)

nmcli general reload || die 'NetworkManager could not reload its configuration'
ok 'NetworkManager defaults and connection profiles updated'

log '[5/7] Configuring encrypted DNS'
write_file /etc/dnscrypt-proxy/dnscrypt-proxy.toml <<'EOF'
listen_addresses = ['127.0.0.1:53']
server_names = ['quad9-dnscrypt-ip4-nofilter-pri', 'dns.digitale-gesellschaft.ch']
# The explicit server list is pinned and must be reviewed periodically.
require_dnssec = true
require_nolog = true
require_nofilter = true
cache = true
cache_size = 4096
cache_min_ttl = 2400
bootstrap_resolvers = ['9.9.9.9:53', '149.112.112.112:53']
ignore_system_dns = true
[sources.public-resolvers]
urls = ['https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md', 'https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md']
cache_file = '/var/cache/dnscrypt-proxy/public-resolvers.md'
minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
refresh_delay = 72
EOF

dnscrypt-proxy -check -config /etc/dnscrypt-proxy/dnscrypt-proxy.toml >/dev/null || die 'dnscrypt-proxy rejected its configuration'
systemctl disable --now dnscrypt-proxy.socket >/dev/null 2>&1 || warn 'could not disable dnscrypt-proxy.socket (it may not be installed)'
systemctl enable dnscrypt-proxy.service || die 'could not enable dnscrypt-proxy.service'
systemctl restart dnscrypt-proxy.service || die 'dnscrypt-proxy failed to start'

DNS_OK=0
for _ in {1..15}; do
  if dig @127.0.0.1 example.com +short +time=2 +tries=1 2>/dev/null | grep -q .; then
    DNS_OK=1
    break
  fi
  sleep 2
done
((DNS_OK == 1)) || die 'DNSCrypt did not answer on 127.0.0.1:53; resolver routing has not been changed'
ok 'DNSCrypt answers locally'

# Switch the host resolver only after the encrypted resolver has passed a query.
DNS_SWITCHED=1
write_file /etc/systemd/resolved.conf.d/moriarty-dns.conf <<'EOF'
[Resolve]
DNS=127.0.0.1
FallbackDNS=
LLMNR=no
MulticastDNS=no
DNSSEC=no
EOF
systemctl try-restart systemd-resolved >/dev/null 2>&1 || warn 'systemd-resolved is not active; its configuration will apply when started'
write_file /etc/resolv.conf <<'EOF'
# Generated by Moriarty. Restore the saved backup to return to the prior resolver.
nameserver 127.0.0.1
options edns0
EOF
nmcli general reload || die 'NetworkManager failed to reload after DNS routing changed'

log '[6/7] Configuring Avahi and UFW sysctl'
set_avahi_publishing_off
if [[ -f /etc/avahi/avahi-daemon.conf ]]; then
  systemctl try-restart avahi-daemon >/dev/null 2>&1 || warn 'Avahi config saved, but avahi-daemon could not be restarted'
fi
if [[ -f /etc/ufw/sysctl.conf ]]; then
  set_ufw_sysctl net/ipv4/conf/all/rp_filter 2
  set_ufw_sysctl net/ipv4/conf/default/rp_filter 2
  set_ufw_sysctl net/ipv4/conf/all/log_martians 1
  set_ufw_sysctl net/ipv4/conf/default/log_martians 1
  ok 'UFW sysctl values aligned'
else
  warn 'UFW sysctl file not found; no UFW firewall rules were installed or enabled'
fi
ok 'resolver, Avahi and optional UFW configuration processed'

log '[7/7] Verifying effective configuration'
systemctl is-active --quiet dnscrypt-proxy.service || die 'dnscrypt-proxy is not active'
dig @127.0.0.1 example.com +time=3 +tries=1 +short | grep -q . || die 'DNSCrypt direct query failed'
dig example.com +time=3 +tries=1 +short | grep -q . || die 'system resolver query failed'

printf '  sysctl: kptr_restrict=%s dmesg_restrict=%s tempaddr=%s\n' \
  "$(sysctl -n kernel.kptr_restrict 2>/dev/null || printf '?')" \
  "$(sysctl -n kernel.dmesg_restrict 2>/dev/null || printf '?')" \
  "$(sysctl -n net.ipv6.conf.all.use_tempaddr 2>/dev/null || printf '?')"
ok 'DNSCrypt and the system resolver respond'

DNS_SWITCHED=0
printf '\n%sCOMPLETE%s\n' "$GREEN" "$RESET"
printf 'Backup: %s\n' "$BACKUP_DIR"
printf 'Restore: sudo ./moriarty-restore.sh %q\n' "$BACKUP_DIR"
printf 'Note: packages installed by Moriarty are intentionally left installed by restore.\n'
printf 'Note: module policy takes full effect after reboot.\n'
