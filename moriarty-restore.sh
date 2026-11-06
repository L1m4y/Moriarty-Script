#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Restore a backup created by moriarty.sh.
#
# The restored paths are limited to a fixed allow-list; a MANIFEST alone can
# never select arbitrary files. v2 manifests are checksummed; v1 manifests
# are accepted with a warning.

set -Eeuo pipefail
IFS=$'\n\t'
export LC_ALL=C

PROG=${0##*/}
VERSION='2.3.4'

DRY_RUN=0
ASSUME_YES=0
LIST_ONLY=0
USE_COLOR=1
BACKUP_DIR=''
LOCK_FILE='/run/lock/moriarty.lock'

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[1;33m'
  BOLD=$'\033[1m'
  RESET=$'\033[0m'
else
  RED=''
  GREEN=''
  YELLOW=''
  BOLD=''
  RESET=''
fi

log() { printf '%s\n' "$*"; }
warn() { printf '  %s[!]%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die() {
  printf '  %s[FAIL]%s %s\n' "$RED" "$RESET" "$*" >&2
  exit 1
}
ok() { printf '  %s[OK]%s %s\n' "$GREEN" "$RESET" "$*"; }

usage() {
  cat <<EOF
$PROG $VERSION - restore a Moriarty backup

Usage: sudo ./$PROG [options] [backup-directory]

Options:
  -h, --help       Show this help and exit
  -V, --version   Show version and exit
  -n, --dry-run    Show what would be restored without writing
  -l, --list       List available backups
  -y, --yes        Skip the confirmation prompt
  --no-color       Disable colored output

If no directory is supplied, the newest /root/moriarty-backup.* directory is
selected.
EOF
}

allowed_path() {
  case "$1" in
    /etc/sysctl.d/99-moriarty-hardening.conf | \
      /etc/sysctl.d/99-moriarty-performance.conf | \
      /etc/sysctl.d/99-hardening.conf | \
      /etc/sysctl.d/99-performance.conf | \
      /etc/modprobe.d/99-moriarty-blacklist.conf | \
      /etc/modprobe.d/blacklist-obscure.conf | \
      /etc/modules-load.d/99-moriarty-bbr.conf | \
      /etc/systemd/network/10-moriarty-random-mac.link | \
      /etc/systemd/network/11-moriarty-random-mac-wifi.link | \
      /etc/systemd/network/10-garbato-random-mac.link | \
      /etc/systemd/network/11-garbato-random-mac-wifi.link | \
      /etc/NetworkManager/conf.d/00-moriarty-identity.conf | \
      /etc/NetworkManager/conf.d/00-mac-ip-randomize.conf | \
      /etc/NetworkManager/conf.d/90-dns-none.conf | \
      /etc/dnscrypt-proxy/dnscrypt-proxy.toml | \
      /etc/resolv.conf | \
      /etc/systemd/resolved.conf.d/99-moriarty-dns.conf | \
      /etc/systemd/resolved.conf.d/moriarty-dns.conf | \
      /etc/systemd/resolved.conf.d/garbato-dns.conf | \
      /etc/avahi/avahi-daemon.conf | \
      /etc/ufw/sysctl.conf)
      return 0
      ;;
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

main() {
  local candidate newest found manifest_version=1
  local -a entries=()
  local action path checksum extra relative saved parent parent_real

  while (($#)); do
    case "$1" in
      -h | --help)
        usage
        exit 0
        ;;
      -V | --version)
        printf '%s %s\n' "$PROG" "$VERSION"
        exit 0
        ;;
      -n | --dry-run) DRY_RUN=1 ;;
      -l | --list) LIST_ONLY=1 ;;
      -y | --yes) ASSUME_YES=1 ;;
      --no-color) USE_COLOR=0 ;;
      -*) die "unknown option: $1 (try --help)" ;;
      *)
        [[ -z "$BACKUP_DIR" ]] || die 'only one backup directory may be supplied'
        BACKUP_DIR=$1
        ;;
    esac
    shift
  done

  if ((USE_COLOR == 0)); then
    RED=''
    GREEN=''
    YELLOW=''
    BOLD=''
    RESET=''
  fi

  if ((LIST_ONLY)); then
    found=0
    for candidate in /root/moriarty-backup.*; do
      [[ -d "$candidate" && ! -L "$candidate" ]] || continue
      printf '%s\n' "$candidate"
      found=1
    done
    ((found)) || log 'No Moriarty backups found.'
    exit 0
  fi

  if [[ -z "$BACKUP_DIR" ]]; then
    newest=''
    for candidate in /root/moriarty-backup.*; do
      [[ -d "$candidate" && ! -L "$candidate" ]] || continue
      if [[ -z "$newest" || "$candidate" -nt "$newest" ]]; then
        newest=$candidate
      fi
    done
    BACKUP_DIR=$newest
  fi

  [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]] ||
    die 'no valid backup directory found'
  [[ ! -L "$BACKUP_DIR" ]] || die 'backup directory must not be a symbolic link'
  command -v realpath >/dev/null 2>&1 || die 'realpath is required'
  command -v stat >/dev/null 2>&1 || die 'stat is required'
  command -v sha256sum >/dev/null 2>&1 || die 'sha256sum is required'
  BACKUP_DIR=$(realpath -e -- "$BACKUP_DIR") || die 'cannot resolve backup directory'
  [[ "${BACKUP_DIR%/*}" == '/root' && "${BACKUP_DIR##*/}" == moriarty-backup.* ]] ||
    die 'backup must be a direct /root/moriarty-backup.* directory'

  [[ $(stat -c '%u' "$BACKUP_DIR") == 0 ]] || die 'backup directory is not owned by root'
  backup_mode=$(stat -c '%a' "$BACKUP_DIR")
  (((8#$backup_mode & 077) == 0)) ||
    die 'backup directory permissions are too broad; expected 0700 or stricter'

  MANIFEST="$BACKUP_DIR/MANIFEST"
  [[ -f "$MANIFEST" && ! -L "$MANIFEST" ]] || die 'MANIFEST is missing or is not a regular file'
  [[ $(stat -c '%u' "$MANIFEST") == 0 ]] || die 'MANIFEST is not owned by root'
  manifest_mode=$(stat -c '%a' "$MANIFEST")
  (((8#$manifest_mode & 077) == 0)) ||
    die 'MANIFEST permissions are too broad; expected 0600 or stricter'

  if ((DRY_RUN == 0)); then
    ((EUID == 0)) || die "run as root: sudo ./$PROG $BACKUP_DIR"
  fi

  if ((ASSUME_YES == 0 && DRY_RUN == 0)); then
    [[ -t 0 ]] || die 'non-interactive shell: use --yes'
    read -r -p 'Restore this backup and overwrite the managed configuration files? [y/N] ' answer
    [[ "$answer" =~ ^([yY]|[yY][eE][sS])$ ]] || {
      log 'Aborted.'
      exit 1
    }
  fi

  log "Backup selected: $BACKUP_DIR"

  if [[ $(head -n 1 -- "$MANIFEST") == '# moriarty-manifest-v2' ]]; then
    manifest_version=2
  else
    manifest_version=1
    warn 'This is a v1 manifest without checksums; continuing without payload verification.'
  fi

  # Validate every manifest entry before changing anything.
  if ((manifest_version == 2)); then
    tail -n +2 "$MANIFEST" >"$BACKUP_DIR/.manifest.entries.$$" || die 'cannot read manifest'
  else
    cat "$MANIFEST" >"$BACKUP_DIR/.manifest.entries.$$"
  fi
  entries_file="$BACKUP_DIR/.manifest.entries.$$"
  while IFS=$'\t' read -r action path extra || [[ -n "${action:-}${path:-}${extra:-}" ]]; do
    [[ -z "${action:-}" && -z "${path:-}" && -z "${extra:-}" ]] && continue
    [[ "${extra:-}" == "" || "$manifest_version" == 1 ]] || true
    [[ -z "${action:-}" || -z "${path:-}" ]] && die 'malformed MANIFEST entry'
    [[ "$action" == modified || "$action" == created ]] || die "unknown MANIFEST action: $action"
    if ((manifest_version == 2)); then
      [[ "$extra" == * ]] || die 'malformed MANIFEST checksum'
    fi
    allowed_path "$path" || die "MANIFEST path is not allowed: $path"
    if [[ " ${entries[*]:-} " == *" $path "* ]]; then
      die "duplicate MANIFEST path: $path"
    fi
    entries+=("$path")
    if [[ "$action" == modified ]]; then
      relative=${path#/}
      saved="$BACKUP_DIR/$relative"
      [[ -e "$saved" || -L "$saved" ]] || die "backup data is missing for $path"
      parent=$(dirname -- "$saved")
      parent_real=$(realpath -e -- "$parent") ||
        die "cannot resolve backup payload parent: $saved"
      [[ "$parent_real" == "$BACKUP_DIR" || "$parent_real" == "$BACKUP_DIR/"* ]] ||
        die "backup payload escapes the backup directory: $path"

      if [[ -L "$saved" ]]; then
        if ((manifest_version == 2)); then
          [[ "$extra" == link:* ]] ||
            die "invalid checksum for symlink $path"
          checksum=$(printf '%s' "${extra#link:}" | base64 -d 2>/dev/null) ||
            die "invalid base64 checksum for $path"
          [[ "$(readlink -- "$saved")" == "$checksum" ]] ||
            die "checksum mismatch for $path"
        fi
      elif [[ ! -f "$saved" ]]; then
        die "backup payload is not a regular file or symlink: $saved"
      else
        if ((manifest_version == 2)); then
          [[ "$extra" =~ ^[0-9a-f]{64}$ ]] || die "invalid checksum for $path"
          [[ "$(sha256sum -- "$saved" | awk '{print $1}')" == "$extra" ]] ||
            die "checksum mismatch for $path"
        fi
      fi
    fi
  done <"$entries_file"
  rm -f -- "$entries_file"

  ((${#entries[@]} > 0)) || warn 'MANIFEST is empty; only runtime state can be restored.'

  # Validate auxiliary snapshots when present.
  for state_file in \
    "$BACKUP_DIR/systemd-units.tsv" \
    "$BACKUP_DIR/sysctl-runtime.tsv" \
    "$BACKUP_DIR/networkmanager-profiles.tsv" \
    "$BACKUP_DIR/networkmanager-identity.tsv"; do
    [[ -e "$state_file" ]] || continue
    [[ ! -L "$state_file" ]] || die "state file must not be a symbolic link: $state_file"
    [[ -f "$state_file" ]] || die "state file is not a regular file: $state_file"
    [[ $(stat -c '%u' "$state_file") == 0 ]] || die "state file is not owned by root: $state_file"
    state_mode=$(stat -c '%a' "$state_file")
    (((8#$state_mode & 077) == 0)) || die "state file permissions are too broad: $state_file"
  done

  # Lock the restore process like the apply process.
  if ((DRY_RUN == 0)); then
    install -d -m 0755 /run/lock
    exec 9>"$LOCK_FILE" 2>/dev/null ||
      die 'cannot open the Moriarty lock file'
    flock -n 9 || die 'another Moriarty process (apply or restore) is already running'
  fi

  log 'Restoring managed files:'
  if ((manifest_version == 2)); then
    tail -n +2 "$MANIFEST"
  else
    cat "$MANIFEST"
  fi | while IFS=$'\t' read -r action path; do
    [[ -n "${path:-}" ]] || continue
    relative=${path#/}
    saved="$BACKUP_DIR/$relative"
    case "$action" in
      modified)
        run install -d -m 0755 -- "$(dirname "$path")"
        if ((DRY_RUN == 0)); then
          temporary=$(mktemp "$(dirname "$path")/.moriarty-restore.XXXXXX")
          cp -aT -- "$saved" "$temporary" || {
            rm -f -- "$temporary"
            die "cannot stage restore for $path"
          }
          sync -- "$temporary" 2>/dev/null || true
          mv -fT -- "$temporary" "$path" ||
            die "cannot install restored $path"
          sync -- "$(dirname "$path")" 2>/dev/null || true
        fi
        log "  restored $path"
        ;;
      created)
        run rm -f -- "$path"
        log "  removed  $path"
        ;;
    esac
  done

  # Saved NetworkManager profile fields.
  restore_networkmanager_profiles

  restore_networkmanager_identity_restore

  log 'Reloading system configuration and restoring runtime state:'
  run systemctl daemon-reload || warn 'systemd daemon-reload failed'
  if command -v sysctl >/dev/null 2>&1; then
    run sysctl --system || warn 'sysctl --system reported an error while loading restored files'
  fi
  if command -v nmcli >/dev/null 2>&1; then
    run nmcli general reload || warn 'NetworkManager reload failed'
  fi

  for unit in NetworkManager.service systemd-resolved.service dnscrypt-proxy.service avahi-daemon.service; do
    run systemctl try-restart "$unit" || true
  done
  restore_systemd_states
  restore_sysctl_runtime

  log ''
  log 'Restore process finished.'
  log 'Review warnings above. Packages installed by Moriarty are intentionally not removed.'
  log 'Some kernel settings cannot be reversed during the same boot (for example kernel.kexec_load_disabled); reboot to clear them.'
}

restore_networkmanager_profiles() {
  local file="$BACKUP_DIR/networkmanager-profiles.tsv"
  local uuid dns4_b64 ignore4_b64 dns6_b64 ignore6_b64
  local dns4 ignore4 dns6 ignore6
  [[ -f "$file" ]] || {
    warn 'No saved NetworkManager profile state; skipping.'
    return 0
  }
  command -v nmcli >/dev/null 2>&1 || {
    warn 'nmcli is unavailable; cannot restore per-profile DNS values.'
    return 0
  }
  while IFS='|' read -r uuid dns4_b64 ignore4_b64 dns6_b64 ignore6_b64 _ _ _; do
    [[ -n "$uuid" ]] || continue
    [[ "$uuid" =~ ^[0-9a-fA-F-]{36}$ ]] || die "invalid UUID in profile backup: $uuid"
    dns4=$(printf '%s' "$dns4_b64" | base64 -d 2>/dev/null) || die "invalid base64 DNS4 value for $uuid"
    ignore4=$(printf '%s' "$ignore4_b64" | base64 -d 2>/dev/null) || die "invalid base64 IPv4 policy for $uuid"
    dns6=$(printf '%s' "$dns6_b64" | base64 -d 2>/dev/null) || die "invalid base64 DNS6 value for $uuid"
    ignore6=$(printf '%s' "$ignore6_b64" | base64 -d 2>/dev/null) || die "invalid base64 IPv6 policy for $uuid"
    run nmcli connection modify "$uuid" \
      ipv4.dns "$dns4" ipv4.ignore-auto-dns "$ignore4" \
      ipv6.dns "$dns6" ipv6.ignore-auto-dns "$ignore6" ||
      warn "could not restore NetworkManager profile $uuid"
  done <"$file"
}

# Backward-compatible placeholder for identity restore. The implementation must
# appear before main() is invoked, but Bash resolves function calls when used.
restore_networkmanager_identity_restore() {
  local file="$BACKUP_DIR/networkmanager-identity.tsv"
  local uuid field value_b64 value
  [[ -f "$file" ]] || return 0
  command -v nmcli >/dev/null 2>&1 || {
    warn 'nmcli is unavailable; cannot restore per-profile identity values.'
    return 0
  }
  while IFS='|' read -r uuid field value_b64; do
    [[ -n "$uuid" ]] || continue
    [[ "$uuid" =~ ^[0-9a-fA-F-]{36}$ ]] || die "invalid UUID in identity backup: $uuid"
    case "$field" in
      connection.stable-id | ethernet.cloned-mac-address | wifi.cloned-mac-address | \
        ipv4.dhcp-client-id | ipv4.dhcp-send-hostname | ipv6.dhcp-send-hostname | \
        ipv6.dhcp-duid | ipv6.addr-gen-mode | ipv6.ip6-privacy) ;;
      *) die "unexpected NetworkManager field in identity backup: $field" ;;
    esac
    value=$(printf '%s' "$value_b64" | base64 -d 2>/dev/null) || die "invalid base64 identity value for $uuid/$field"
    run nmcli connection modify "$uuid" "$field" "$value" ||
      warn "could not restore identity field $field on profile $uuid"
  done <"$file"
}

restore_sysctl_runtime() {
  local file="$BACKUP_DIR/sysctl-runtime.tsv"
  local key encoded value
  [[ -f "$file" ]] || {
    warn 'No sysctl runtime snapshot; persistent files were restored only.'
    return 0
  }
  command -v sysctl >/dev/null 2>&1 || {
    warn 'sysctl is unavailable; runtime values were not restored.'
    return 0
  }
  while IFS=$'\t' read -r key encoded; do
    [[ -n "$key" ]] || continue
    case "$key" in
      kernel.kptr_restrict | kernel.dmesg_restrict | kernel.printk | kernel.sysrq | \
        kernel.yama.ptrace_scope | kernel.unprivileged_bpf_disabled | \
        kernel.io_uring_disabled | kernel.kexec_load_disabled | \
        kernel.perf_event_paranoid | kernel.oops_limit | kernel.panic | \
        vm.mmap_rnd_bits | vm.mmap_rnd_compat_bits | vm.unprivileged_userfaultfd | \
        net.core.bpf_jit_harden | net.core.default_qdisc | \
        dev.tty.ldisc_autoload | dev.tty.legacy_tiocsti | \
        fs.protected_fifos | fs.protected_regular | fs.protected_symlinks | \
        fs.protected_hardlinks | fs.suid_dumpable | \
        net.ipv4.conf.all.accept_redirects | net.ipv4.conf.default.accept_redirects | \
        net.ipv4.conf.all.secure_redirects | net.ipv4.conf.default.secure_redirects | \
        net.ipv4.conf.all.send_redirects | net.ipv4.conf.default.send_redirects | \
        net.ipv4.conf.all.accept_source_route | net.ipv4.conf.default.accept_source_route | \
        net.ipv4.conf.all.log_martians | net.ipv4.conf.default.log_martians | \
        net.ipv4.conf.all.rp_filter | net.ipv4.conf.default.rp_filter | \
        net.ipv4.conf.all.arp_filter | net.ipv4.conf.default.arp_filter | \
        net.ipv4.conf.all.arp_ignore | net.ipv4.conf.all.arp_announce | \
        net.ipv4.tcp_syncookies | net.ipv4.tcp_rfc1337 | net.ipv4.tcp_synack_retries | \
        net.ipv4.tcp_max_syn_backlog | net.ipv4.tcp_slow_start_after_idle | \
        net.ipv4.tcp_congestion_control | net.ipv6.conf.all.accept_redirects | \
        net.ipv6.conf.default.accept_redirects | net.ipv6.conf.all.accept_source_route | \
        net.ipv6.conf.default.accept_source_route | \
        net.ipv6.conf.all.use_tempaddr | net.ipv6.conf.default.use_tempaddr) ;;
      *) die "unexpected sysctl key in backup: $key" ;;
    esac
    value=$(printf '%s' "$encoded" | base64 -d 2>/dev/null) || die "invalid sysctl snapshot for $key"
    run sysctl -w "$key=$value" ||
      warn "could not restore runtime sysctl $key (a reboot may be required)"
  done <"$file"
}

restore_systemd_states() {
  local file="$BACKUP_DIR/systemd-units.tsv"
  local unit enabled active
  [[ -f "$file" ]] || {
    warn 'No systemd service-state snapshot; service states cannot be restored exactly.'
    return 0
  }
  command -v systemctl >/dev/null 2>&1 || {
    warn 'systemctl is unavailable; skipping unit-state restoration.'
    return 0
  }
  while IFS=$'\t' read -r unit enabled active; do
    [[ -n "$unit" ]] || continue
    case "$unit" in
      dnscrypt-proxy.service | dnscrypt-proxy.socket | NetworkManager.service | \
        systemd-resolved.service | avahi-daemon.service) ;;
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
      static | indirect | generated | transient | alias | linked | linked-runtime | '') ;;
      *) warn "unrecognized enable state '$enabled' for $unit; leaving it unchanged" ;;
    esac
  done <"$file"

  while IFS=$'\t' read -r unit enabled active; do
    [[ -n "$unit" ]] || continue
    case "$active" in
      active) run systemctl start "$unit" || warn "could not start $unit" ;;
      inactive | failed | unknown | not-found | '') run systemctl stop "$unit" || true ;;
      *) warn "unrecognized active state '$active' for $unit; leaving it unchanged" ;;
    esac
  done <"$file"
}

main "$@"
