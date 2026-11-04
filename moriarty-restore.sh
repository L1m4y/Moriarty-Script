#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Restore a backup created by moriarty.sh. Only an explicit path allow-list is accepted.

set -Eeuo pipefail
IFS=$'\n\t'

PROG=${0##*/}
DRY_RUN=0
ASSUME_YES=0
LIST_ONLY=0
BACKUP_DIR=''

usage() {
  cat <<EOF
$PROG - restore a Moriarty backup

Usage: sudo ./$PROG [options] [backup-directory]

Options:
  -h, --help       Show this help and exit
  -n, --dry-run    Show what would be restored
  -l, --list       List available backups
  -y, --yes        Do not ask for confirmation

If no directory is supplied, the newest /root/moriarty-backup.* is selected.
EOF
}

log()  { printf '%s\n' "$*"; }
warn() { printf '  [!] %s\n' "$*" >&2; }
die()  { printf '  [FAIL] %s\n' "$*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -n|--dry-run) DRY_RUN=1 ;;
    -l|--list) LIST_ONLY=1 ;;
    -y|--yes) ASSUME_YES=1 ;;
    -*) die "unknown option: $1 (try --help)" ;;
    *) [[ -z "$BACKUP_DIR" ]] || die 'only one backup directory may be supplied'; BACKUP_DIR=$1 ;;
  esac
  shift
done

if ((LIST_ONLY)); then
  found=0
  for candidate in /root/moriarty-backup.*; do
    [[ -d "$candidate" && ! -L "$candidate" && "$candidate" != *.DRYRUN ]] || continue
    printf '%s\n' "$candidate"
    found=1
  done
  ((found)) || log 'No Moriarty backups found.'
  exit 0
fi

if [[ -z "$BACKUP_DIR" ]]; then
  newest=''
  for candidate in /root/moriarty-backup.*; do
    [[ -d "$candidate" && ! -L "$candidate" && "$candidate" != *.DRYRUN ]] || continue
    if [[ -z "$newest" || "$candidate" -nt "$newest" ]]; then newest=$candidate; fi
  done
  BACKUP_DIR=$newest
fi

[[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]] || die 'no valid backup directory found'
command -v systemctl >/dev/null 2>&1 || die 'systemctl is required to restore service state'
[[ ! -L "$BACKUP_DIR" ]] || die 'backup directory must not be a symbolic link'
command -v realpath >/dev/null 2>&1 || die 'realpath is required'
command -v stat >/dev/null 2>&1 || die 'stat is required'
BACKUP_DIR=$(realpath -e -- "$BACKUP_DIR") || die 'cannot resolve backup directory'
[[ "${BACKUP_DIR%/*}" == '/root' && "${BACKUP_DIR##*/}" == moriarty-backup.* ]] || die 'backup must be a direct /root/moriarty-backup.* directory'

[[ $(stat -c '%u' "$BACKUP_DIR") == 0 ]] || die 'backup directory is not owned by root'
backup_mode=$(stat -c '%a' "$BACKUP_DIR")
(( (8#$backup_mode & 077) == 0 )) || die 'backup directory permissions are too broad; expected 0700 or stricter'
MANIFEST="$BACKUP_DIR/MANIFEST"
[[ -f "$MANIFEST" && ! -L "$MANIFEST" ]] || die 'MANIFEST is missing or is not a regular file'
[[ $(stat -c '%u' "$MANIFEST") == 0 ]] || die 'MANIFEST is not owned by root'
manifest_mode=$(stat -c '%a' "$MANIFEST")
(( (8#$manifest_mode & 077) == 0 )) || die 'MANIFEST permissions are too broad; expected 0600 or stricter'

if ((DRY_RUN == 0)); then
  ((EUID == 0)) || die "run as root: sudo ./$PROG $BACKUP_DIR"
fi

# These are the only filesystem paths that this restore tool may modify.
allowed_path() {
  case "$1" in
    /etc/sysctl.d/99-hardening.conf|\
    /etc/sysctl.d/99-performance.conf|\
    /etc/modprobe.d/blacklist-obscure.conf|\
    /etc/systemd/network/10-moriarty-random-mac.link|\
    /etc/systemd/network/11-moriarty-random-mac-wifi.link|\
    /etc/NetworkManager/conf.d/00-mac-ip-randomize.conf|\
    /etc/NetworkManager/conf.d/90-dns-none.conf|\
    /etc/dnscrypt-proxy/dnscrypt-proxy.toml|\
    /etc/resolv.conf|\
    /etc/systemd/resolved.conf.d/moriarty-dns.conf|\
    /etc/avahi/avahi-daemon.conf|\
    /etc/ufw/sysctl.conf) return 0 ;;
    *) return 1 ;;
  esac
}

run() {
  if ((DRY_RUN)); then
    printf '  [dry-run]'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

log "Backup selected: $BACKUP_DIR"
if ((DRY_RUN == 0 && ASSUME_YES == 0)); then
  [[ -t 0 ]] || die 'non-interactive shell: use --yes'
  read -r -p 'Restore this backup and overwrite the managed configuration files? [y/N] ' answer
  [[ "$answer" =~ ^([yY]|[yY][eE][sS])$ ]] || { log 'Aborted.'; exit 1; }
fi

# Parse and validate the entire manifest before changing anything.
manifest_count=0
while IFS=$'\t' read -r action path extra || [[ -n "${action:-}${path:-}${extra:-}" ]]; do
  [[ -z "${extra:-}" && -n "${action:-}" && -n "${path:-}" ]] || die 'malformed MANIFEST entry'
  [[ "$action" == modified || "$action" == created ]] || die "unknown MANIFEST action: $action"
  allowed_path "$path" || die "MANIFEST path is not allowed: $path"
  if [[ "$action" == modified ]]; then
    relative=${path#/}
    saved="$BACKUP_DIR/$relative"
    [[ -e "$saved" || -L "$saved" ]] || die "backup data is missing for $path"
  fi
  ((manifest_count += 1))
done < "$MANIFEST"

((manifest_count > 0)) || warn 'MANIFEST is empty; only auxiliary state files can be restored.'

log 'Restoring managed files:'
while IFS=$'\t' read -r action path; do
  [[ -n "${path:-}" ]] || continue
  relative=${path#/}
  saved="$BACKUP_DIR/$relative"
  case "$action" in
    modified)
      run install -d -m 0755 -- "$(dirname "$path")"
      run cp -aT -- "$saved" "$path"
      log "  restored $path"
      ;;
    created)
      run rm -f -- "$path"
      log "  removed  $path"
      ;;
  esac
done < "$MANIFEST"

restore_networkmanager_profiles() {
  local file="$BACKUP_DIR/networkmanager-profiles.tsv"
  local uuid dns4_b64 ignore4_b64 dns6_b64 ignore6_b64 dns4 ignore4 dns6 ignore6
  [[ -f "$file" ]] || { warn 'No saved NetworkManager profile state; skipping.'; return 0; }
  command -v nmcli >/dev/null 2>&1 || { warn 'nmcli is unavailable; cannot restore per-profile DNS values.'; return 0; }
  while IFS='|' read -r uuid dns4_b64 ignore4_b64 dns6_b64 ignore6_b64; do
    [[ -n "$uuid" ]] || continue
    [[ "$uuid" =~ ^[0-9a-fA-F-]{36}$ ]] || die "invalid UUID in profile backup: $uuid"
    dns4=$(printf '%s' "$dns4_b64" | base64 -d) || die "invalid base64 DNS4 value for $uuid"
    ignore4=$(printf '%s' "$ignore4_b64" | base64 -d) || die "invalid base64 IPv4 policy for $uuid"
    dns6=$(printf '%s' "$dns6_b64" | base64 -d) || die "invalid base64 DNS6 value for $uuid"
    ignore6=$(printf '%s' "$ignore6_b64" | base64 -d) || die "invalid base64 IPv6 policy for $uuid"
    run nmcli connection modify "$uuid" \
      ipv4.dns "$dns4" ipv4.ignore-auto-dns "$ignore4" \
      ipv6.dns "$dns6" ipv6.ignore-auto-dns "$ignore6" \
      || warn "could not restore NetworkManager profile $uuid"
  done < "$file"
}

restore_sysctl_runtime() {
  local file="$BACKUP_DIR/sysctl-runtime.tsv"
  local key encoded value
  [[ -f "$file" ]] || { warn 'No sysctl runtime snapshot; persistent files were restored only.'; return 0; }
  command -v sysctl >/dev/null 2>&1 || { warn 'sysctl is unavailable; runtime values were not restored.'; return 0; }
  while IFS=$'\t' read -r key encoded; do
    [[ -n "$key" ]] || continue
    # Do not accept arbitrary sysctl names from a modified backup.
    case "$key" in
      kernel.kptr_restrict|kernel.dmesg_restrict|kernel.printk|vm.mmap_rnd_bits|vm.mmap_rnd_compat_bits|net.core.bpf_jit_harden|kernel.sysrq|dev.tty.ldisc_autoload|vm.unprivileged_userfaultfd|dev.tty.legacy_tiocsti|fs.protected_fifos|fs.protected_regular|net.ipv4.conf.all.accept_redirects|net.ipv4.conf.default.accept_redirects|net.ipv4.conf.all.secure_redirects|net.ipv4.conf.default.secure_redirects|net.ipv4.conf.all.send_redirects|net.ipv4.conf.default.send_redirects|net.ipv6.conf.all.accept_source_route|net.ipv6.conf.default.accept_source_route|net.ipv4.conf.all.log_martians|net.ipv4.conf.default.log_martians|net.ipv4.conf.all.arp_filter|net.ipv4.conf.default.arp_filter|net.ipv4.conf.all.arp_ignore|net.ipv4.conf.all.arp_announce|net.ipv4.tcp_synack_retries|net.ipv4.tcp_rfc1337|net.ipv6.conf.all.use_tempaddr|net.ipv6.conf.default.use_tempaddr|net.ipv6.conf.all.accept_redirects|net.ipv6.conf.default.accept_redirects|net.core.default_qdisc|net.ipv4.tcp_max_syn_backlog|net.ipv4.tcp_slow_start_after_idle|net.ipv4.tcp_congestion_control|net.ipv4.conf.all.rp_filter|net.ipv4.conf.default.rp_filter) ;;
      *) die "unexpected sysctl key in backup: $key" ;;
    esac
    value=$(printf '%s' "$encoded" | base64 -d) || die "invalid sysctl snapshot for $key"
    run sysctl -w "$key=$value" || warn "could not restore runtime sysctl $key (a reboot may be required)"
  done < "$file"
}

restore_systemd_states() {
  local file="$BACKUP_DIR/systemd-units.tsv"
  local unit enabled active
  [[ -f "$file" ]] || { warn 'No systemd service-state snapshot; service states cannot be restored exactly.'; return 0; }
  command -v systemctl >/dev/null 2>&1 || { warn 'systemctl is unavailable; skipping unit-state restoration.'; return 0; }

  while IFS=$'\t' read -r unit enabled active; do
    [[ -n "$unit" ]] || continue
    case "$unit" in
      dnscrypt-proxy.service|dnscrypt-proxy.socket|NetworkManager.service|systemd-resolved.service|avahi-daemon.service) ;;
      *) die "unexpected systemd unit in backup: $unit" ;;
    esac
    case "$enabled" in
      enabled) run systemctl enable "$unit" || warn "could not enable $unit" ;;
      enabled-runtime) run systemctl enable --runtime "$unit" || warn "could not runtime-enable $unit" ;;
      disabled) run systemctl disable "$unit" || warn "could not disable $unit" ;;
      disabled-runtime) run systemctl disable --runtime "$unit" || warn "could not runtime-disable $unit" ;;
      masked) run systemctl mask "$unit" || warn "could not mask $unit" ;;
      masked-runtime) run systemctl mask --runtime "$unit" || warn "could not runtime-mask $unit" ;;
      not-found) run systemctl disable "$unit" || true ;;
      static|indirect|generated|transient|alias|linked|linked-runtime|'') ;;
      *) warn "unrecognized enable state '$enabled' for $unit; leaving it unchanged" ;;
    esac
  done < "$file"

  while IFS=$'\t' read -r unit enabled active; do
    [[ -n "$unit" ]] || continue
    case "$active" in
      active) run systemctl start "$unit" || warn "could not start $unit" ;;
      inactive|failed|unknown|not-found|'') run systemctl stop "$unit" || true ;;
      *) warn "unrecognized active state '$active' for $unit; leaving it unchanged" ;;
    esac
  done < "$file"
}

log 'Reloading system configuration and restoring runtime state:'
run systemctl daemon-reload || warn 'systemd daemon-reload failed'
if command -v sysctl >/dev/null 2>&1; then
  run sysctl --system || warn 'sysctl --system reported an error while loading restored files'
fi
restore_networkmanager_profiles
if command -v nmcli >/dev/null 2>&1; then
  run nmcli general reload || warn 'NetworkManager reload failed'
fi

# Restart only units already active now; afterward, restore their original
# enabled and active states from the snapshot.
for unit in NetworkManager.service systemd-resolved.service dnscrypt-proxy.service avahi-daemon.service; do
  run systemctl try-restart "$unit" || true
done
restore_systemd_states
restore_sysctl_runtime

log ''
log 'Restore process finished.'
log 'Review warnings above. Packages installed by Moriarty are intentionally not removed.'
log 'Some kernel settings cannot be reversed during the same boot; reboot if a runtime sysctl refused restoration.'
