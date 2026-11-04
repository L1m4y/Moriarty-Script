#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Moriarty - host privacy/hardening profile for Arch Linux and derivatives.
#
# Requires: systemd, NetworkManager (unless --skip-network), pacman,
# dnscrypt-proxy and bind (installed by the DNS phase unless --skip-dns).

set -Eeuo pipefail
IFS=$'\n\t'
export LC_ALL=C

PROG=${0##*/}
VERSION='2.3.2'

PROFILE='balanced'
DRY_RUN=0
CHECK_ONLY=0
ASSUME_YES=0
USE_COLOR=1
ROLLBACK_ON_ERROR=1
SKIP_MODULES=0
SKIP_NETWORK=0
SKIP_DNS=0
SKIP_AVAHI=0
SKIP_UFW=0
FORCE_PROFILE_DNS=0
FORCE_PROFILE_IDENTITY=0

BACKUP_DIR=''
MANIFEST=''
REPORT_FILE=''
CHANGES_STARTED=0
LOCK_FILE='/run/lock/moriarty.lock'

SYSCTL_APPLIED=0
SYSCTL_UNSUPPORTED=0
SYSCTL_REJECTED=0
SYSCTL_MISMATCH=0
SYSCTL_FAILURES=0
WARNINGS=0

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
ok() { printf '  %s[OK]%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() {
  WARNINGS=$((WARNINGS + 1))
  printf '  %s[!]%s %s\n' "$YELLOW" "$RESET" "$*" >&2
}
die() {
  printf '  %s[FAIL]%s %s\n' "$RED" "$RESET" "$*" >&2
  exit 1
}
section() { printf '\n%s== %s ==%s\n' "$BOLD" "$*" "$RESET"; }

usage() {
  cat <<EOF
$PROG $VERSION - privacy and host hardening for Arch Linux

Usage: sudo ./$PROG [options]

Profiles:
  --profile balanced   Default: strong hardening with live-media compatibility
  --profile strict     Adds kexec/panic hardening and blocks squashfs/udf

Components (all enabled by default):
  --skip-modules       Do not write the modprobe blacklist
  --skip-network       Do not change NetworkManager identity or profile DNS
  --skip-dns           Do not install/configure dnscrypt-proxy or resolv.conf
  --skip-avahi         Do not change Avahi publishing
  --skip-ufw           Do not align /etc/ufw/sysctl.conf

Safety:
  --force-profile-dns       Also clear DNS on manual/static profiles
  --force-profile-identity  Set per-profile stable identity, not only defaults
  --no-rollback             Keep partial changes if a phase fails
  -n, --dry-run             Show planned operations without changing the system
  --check                   Audit the current state without changing anything
  -y, --yes                 Do not ask for confirmation
      --no-color            Disable colored output
  -h, --help                Show this help and exit
  -V, --version             Show version and exit

A root-owned backup and a machine-readable report are created in
/root/moriarty-backup.*. Restore with:
  sudo ./moriarty-restore.sh [backup-directory]

Limitations: encrypted DNS hides the resolver, not the destination address or
TLS SNI. MAC rotation is not anonymity. The module policy blocks modprobe
autoloading only; built-in modules and manual insmod are out of scope.
EOF
}

normalize_ws() {
  printf '%s' "$1" | tr -s '[:space:]' ' ' | sed -E 's/^ //; s/ $//'
}

b64() { printf '%s' "$1" | base64 -w0; }
unb64() { printf '%s' "$1" | base64 -d; }

sha256_of() {
  sha256sum -- "$1" | awk '{print $1}'
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
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

report_section() {
  [[ -n "$REPORT_FILE" ]] || return 0
  printf '\n== %s ==\n' "$1" >>"$REPORT_FILE"
}

report_line() {
  local status=$1 message=$2
  [[ -n "$REPORT_FILE" ]] || return 0
  printf '[%s] %s\n' "$status" "$message" >>"$REPORT_FILE"
}

record_status() {
  local status=$1 message=$2
  report_line "$status" "$message"
  case "$status" in
    applied) ;;
    *) warn "$message" ;;
  esac
}

manifest_has() {
  local action=$1 path=$2
  [[ -f "$MANIFEST" ]] || return 1
  awk -F '\t' -v a="$action" -v p="$path" \
    '$1 == a && $2 == p { found=1 } END { exit !found }' "$MANIFEST"
}

backup_path() {
  local source=$1 relative target checksum
  ((DRY_RUN)) && return 0
  relative=${source#/}
  manifest_has modified "$source" && return 0
  manifest_has created "$source" && return 0
  target="$BACKUP_DIR/$relative"
  if [[ -L "$source" ]]; then
    install -d -m 0700 -- "$(dirname "$target")"
    cp -aT -- "$source" "$target" || die "could not back up symlink $source"
    checksum="link:$(readlink -- "$source" | base64 -w0)"
    printf 'modified\t%s\t%s\n' "$source" "$checksum" >>"$MANIFEST"
  elif [[ -f "$source" ]]; then
    install -d -m 0700 -- "$(dirname "$target")"
    cp -aT -- "$source" "$target" || die "could not back up $source"
    checksum=$(sha256_of "$target")
    printf 'modified\t%s\t%s\n' "$source" "$checksum" >>"$MANIFEST"
  elif [[ -e "$source" ]]; then
    die "refusing to back up non-regular path: $source"
  else
    printf 'created\t%s\t-\n' "$source" >>"$MANIFEST"
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
  temporary=$(mktemp "$directory/.${destination##*/}.moriarty.XXXXXX") ||
    die "cannot create temporary file for $destination"
  if ! cat >"$temporary"; then
    rm -f -- "$temporary"
    die "cannot write temporary file for $destination"
  fi
  if [[ -f "$destination" && ! -L "$destination" ]]; then
    chmod --reference="$destination" "$temporary" ||
      die "cannot preserve mode of $destination"
    chown --reference="$destination" "$temporary" 2>/dev/null || true
  else
    chmod 0644 "$temporary"
  fi
  sync -- "$temporary" 2>/dev/null || true
  if ! mv -fT -- "$temporary" "$destination"; then
    rm -f -- "$temporary"
    die "cannot install $destination"
  fi
  sync -- "$directory" 2>/dev/null || true
}

remove_managed_path() {
  local path=$1
  [[ -e "$path" || -L "$path" ]] || return 0
  backup_path "$path"
  if ((DRY_RUN)); then
    printf '  [dry-run] would remove %s\n' "$path"
  else
    rm -f -- "$path" || die "cannot remove $path"
  fi
}

restore_one_path() {
  local path=$1 relative saved
  ((DRY_RUN)) && return 0
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

# ---------------------------------------------------------------------------
# Sysctl policy
# ---------------------------------------------------------------------------

build_sysctl_candidate() {
  local output=$1
  cat >"$output" <<'EOF'
# Moriarty: balanced hardening profile.
# Values are applied and verified individually; unsupported keys are omitted
# from the persistent file so that boot does not fail on older kernels.
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.printk = 3 3 3 3
kernel.yama.ptrace_scope = 1
kernel.unprivileged_bpf_disabled = 1
kernel.io_uring_disabled = 1
vm.mmap_rnd_bits = 32
vm.mmap_rnd_compat_bits = 16
net.core.bpf_jit_harden = 2
kernel.sysrq = 0
dev.tty.ldisc_autoload = 0
vm.unprivileged_userfaultfd = 0
dev.tty.legacy_tiocsti = 0
fs.protected_fifos = 2
fs.protected_regular = 2
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
fs.suid_dumpable = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.arp_filter = 1
net.ipv4.conf.default.arp_filter = 1
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.all.arp_announce = 2
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_synack_retries = 2
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv6.conf.all.use_tempaddr = 2
net.ipv6.conf.default.use_tempaddr = 2
EOF

  if [[ "$PROFILE" == 'strict' ]]; then
    cat >>"$output" <<'EOF'

# Strict-only settings. kexec_load_disabled is irreversible until reboot.
kernel.kexec_load_disabled = 1
kernel.perf_event_paranoid = 3
kernel.oops_limit = 1
kernel.panic = 30
EOF
  fi
}

ensure_bbr_module() {
  sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr && return 0
  modprobe tcp_bbr 2>/dev/null || return 1
  # Persist the module so the sysctl setting also applies on the next boot.
  write_file /etc/modules-load.d/99-moriarty-bbr.conf <<'EOF'
# Moriarty: load BBR so the persisted congestion-control setting works at boot.
tcp_bbr
EOF
}

build_performance_candidate() {
  local output=$1
  cat >"$output" <<'EOF'
# Moriarty: performance tuning, deliberately separate from security policy.
net.core.default_qdisc = fq
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_slow_start_after_idle = 0
EOF
  if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    printf '\nnet.ipv4.tcp_congestion_control = bbr\n' >>"$output"
  else
    warn 'BBR is unavailable (tcp_bbr could not be loaded); leaving congestion control unchanged.'
  fi
}

is_mandatory_sysctl() {
  case "$1" in
    kernel.kptr_restrict | kernel.dmesg_restrict | kernel.printk | kernel.sysrq | \
      fs.protected_fifos | fs.protected_regular | fs.protected_symlinks | \
      fs.protected_hardlinks | fs.suid_dumpable | \
      net.ipv4.conf.all.accept_redirects | net.ipv4.conf.default.accept_redirects | \
      net.ipv4.conf.all.secure_redirects | net.ipv4.conf.default.secure_redirects | \
      net.ipv4.conf.all.send_redirects | net.ipv4.conf.default.send_redirects | \
      net.ipv4.conf.all.accept_source_route | net.ipv4.conf.default.accept_source_route | \
      net.ipv4.conf.all.log_martians | net.ipv4.conf.default.log_martians | \
      net.ipv4.conf.all.rp_filter | net.ipv4.conf.default.rp_filter | \
      net.ipv4.tcp_syncookies)
      return 0
      ;;
    *) return 1 ;;
  esac
}

capture_sysctl_state() {
  local candidate=$1 performance=$2 key value encoded
  local -A seen=()
  : >"$BACKUP_DIR/sysctl-runtime.tsv"
  chmod 0600 "$BACKUP_DIR/sysctl-runtime.tsv"
  for source in "$candidate" "$performance"; do
    while IFS='=' read -r key value; do
      key=$(printf '%s' "$key" | tr -d '[:space:]')
      [[ -n "$key" && "$key" != \#* ]] || continue
      [[ -z ${seen[$key]:-} ]] || continue
      seen[$key]=1
      if value=$(sysctl -n "$key" 2>/dev/null); then
        encoded=$(printf '%s' "$value" | base64 -w0)
        printf '%s\t%s\n' "$key" "$encoded" >>"$BACKUP_DIR/sysctl-runtime.tsv"
      fi
    done <"$source"
  done
  for key in \
    net.ipv4.conf.all.rp_filter net.ipv4.conf.default.rp_filter \
    net.ipv4.conf.all.log_martians net.ipv4.conf.default.log_martians; do
    [[ -z ${seen[$key]:-} ]] || continue
    seen[$key]=1
    if value=$(sysctl -n "$key" 2>/dev/null); then
      encoded=$(printf '%s' "$value" | base64 -w0)
      printf '%s\t%s\n' "$key" "$encoded" >>"$BACKUP_DIR/sysctl-runtime.tsv"
    fi
  done
}

apply_sysctl_profile() {
  local candidate=$1 destination=$2 label=$3
  local line key expected current actual temporary
  local normalized_expected normalized_actual
  temporary=$(mktemp "$BACKUP_DIR/sysctl-filtered.XXXXXX")
  report_section "$label"
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    key=${line%%=*}
    expected=${line#*=}
    key=$(printf '%s' "$key" | tr -d '[:space:]')
    expected=$(printf '%s' "$expected" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    if ! current=$(sysctl -n "$key" 2>/dev/null); then
      record_status 'unsupported' "$key is not present in this kernel"
      SYSCTL_UNSUPPORTED=$((SYSCTL_UNSUPPORTED + 1))
      if is_mandatory_sysctl "$key"; then
        SYSCTL_FAILURES=$((SYSCTL_FAILURES + 1))
      fi
      continue
    fi
    normalized_expected=$(normalize_ws "$expected")
    normalized_actual=$(normalize_ws "$current")
    if [[ "$normalized_actual" == "$normalized_expected" ]]; then
      report_line 'applied' "$key = $expected (already set)"
      printf '%s = %s\n' "$key" "$expected" >>"$temporary"
      continue
    fi
    if sysctl -w "$key=$expected" >/dev/null 2>&1; then
      actual=$(sysctl -n "$key" 2>/dev/null || true)
      normalized_actual=$(normalize_ws "$actual")
      printf '%s = %s\n' "$key" "$expected" >>"$temporary"
      if [[ "$normalized_actual" != "$normalized_expected" ]]; then
        # The post-load verification counts the mismatch after sysctl --system.
        report_line 'mismatch' "$key expected '$expected', kernel reports '$actual'"
      fi
    else
      record_status 'rejected' "$key = $expected was rejected by the kernel"
      SYSCTL_REJECTED=$((SYSCTL_REJECTED + 1))
      if is_mandatory_sysctl "$key"; then
        SYSCTL_FAILURES=$((SYSCTL_FAILURES + 1))
      fi
    fi
  done <"$candidate"

  if [[ -s "$temporary" ]]; then
    write_file "$destination" <"$temporary"
  else
    warn "no applicable settings for $label"
  fi
  rm -f -- "$temporary"
}

apply_performance_profile() {
  local candidate=$1 destination=$2
  write_file "$destination" <"$candidate"
}

load_and_verify_sysctl() {
  local log line key expected actual path rejected=0
  log=$(mktemp /tmp/moriarty-sysctl.XXXXXX)
  report_section 'sysctl load'
  if ! sysctl --system >"$log" 2>&1; then
    for path in "$@"; do
      if grep -Fq -- "$(basename "$path")" "$log"; then
        rejected=1
      fi
    done
    if ((rejected)); then
      cat "$log" >&2
      rm -f -- "$log"
      die 'sysctl --system rejected a Moriarty profile'
    fi
    warn 'sysctl --system reported errors in files not owned by Moriarty; see report'
    while IFS= read -r line; do
      report_line 'warning' "sysctl --system: $line"
    done <"$log"
    cat "$log" >&2
  fi
  rm -f -- "$log"

  for path in "$@"; do
    while IFS='=' read -r key expected; do
      key=$(printf '%s' "$key" | tr -d '[:space:]')
      [[ -n "$key" && "$key" != \#* ]] || continue
      expected=$(printf '%s' "$expected" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
      actual=$(sysctl -n "$key" 2>/dev/null || true)
      if [[ -z "$actual" ]]; then
        record_status 'unsupported' "$key is not present after loading the profile"
        SYSCTL_UNSUPPORTED=$((SYSCTL_UNSUPPORTED + 1))
        if is_mandatory_sysctl "$key"; then
          SYSCTL_FAILURES=$((SYSCTL_FAILURES + 1))
        fi
        continue
      fi
      if [[ "$(normalize_ws "$actual")" != "$(normalize_ws "$expected")" ]]; then
        record_status 'mismatch' "$key was overridden after sysctl --system (expected '$expected', got '$actual')"
        SYSCTL_MISMATCH=$((SYSCTL_MISMATCH + 1))
        if is_mandatory_sysctl "$key"; then
          SYSCTL_FAILURES=$((SYSCTL_FAILURES + 1))
        fi
      else
        report_line 'applied' "$key = $expected"
        SYSCTL_APPLIED=$((SYSCTL_APPLIED + 1))
      fi
    done <"$path"
  done

  ((SYSCTL_FAILURES == 0)) ||
    die "mandatory sysctl settings failed; review $REPORT_FILE"
  ok 'sysctl profile applied and verified'
}

check_sysctl_candidate() {
  local candidate=$1 line key expected actual
  report_section 'sysctl audit'
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    key=${line%%=*}
    expected=${line#*=}
    key=$(printf '%s' "$key" | tr -d '[:space:]')
    expected=$(printf '%s' "$expected" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    if ! actual=$(sysctl -n "$key" 2>/dev/null); then
      record_status 'unsupported' "$key is not present in this kernel"
      SYSCTL_UNSUPPORTED=$((SYSCTL_UNSUPPORTED + 1))
      if is_mandatory_sysctl "$key"; then
        SYSCTL_FAILURES=$((SYSCTL_FAILURES + 1))
      fi
      continue
    fi
    if [[ "$(normalize_ws "$actual")" == "$(normalize_ws "$expected")" ]]; then
      report_line 'applied' "$key = $expected"
      SYSCTL_APPLIED=$((SYSCTL_APPLIED + 1))
    else
      record_status 'mismatch' "$key expected '$expected', current value '$actual'"
      SYSCTL_MISMATCH=$((SYSCTL_MISMATCH + 1))
      if is_mandatory_sysctl "$key"; then
        SYSCTL_FAILURES=$((SYSCTL_FAILURES + 1))
      fi
    fi
  done <"$candidate"
}

# ---------------------------------------------------------------------------
# Module policy
# ---------------------------------------------------------------------------

module_list() {
  cat <<'EOF'
dccp
sctp
rds
tipc
n-hdlc
ax25
netrom
x25
rose
decnet
econet
af_802154
ipx
appletalk
psnap
p8023
p8022
can
atm
cramfs
freevxfs
jffs2
hfs
hfsplus
vivid
EOF
  if [[ "$PROFILE" == 'strict' ]]; then
    printf '%s\n' squashfs udf
  fi
}

write_module_policy() {
  local destination=$1 module temporary
  temporary=$(mktemp "$BACKUP_DIR/modules.XXXXXX")
  {
    printf '%s\n' \
      '# Moriarty: prevents normal modprobe loading of rarely used protocols/filesystems.' \
      '# This does not unload modules already in use, block built-in features, or' \
      '# prevent a privileged manual insmod. Full effect requires a reboot.'
    while IFS= read -r module; do
      printf 'install %s /bin/false\n' "$module"
    done < <(module_list)
  } >"$temporary"
  write_file "$destination" <"$temporary"
  rm -f -- "$temporary"
}

verify_module_policy() {
  local destination=$1 module output
  report_section 'module policy'
  if [[ ! -f "$destination" ]]; then
    record_status 'missing' "$destination is missing"
    return 0
  fi
  while IFS= read -r module; do
    output=$(modprobe -n -v "$module" 2>/dev/null || true)
    if grep -Fq 'install /bin/false' <<<"$output"; then
      report_line 'applied' "modprobe rule active for $module"
    elif [[ -z "$output" ]]; then
      report_line 'unsupported' "module $module is not available on this kernel"
    else
      record_status 'pending' "module $module is not blocked yet; reboot may be required"
    fi
  done < <(module_list)
}

# ---------------------------------------------------------------------------
# NetworkManager
# ---------------------------------------------------------------------------

nm_value() {
  local uuid=$1 field=$2 value
  value=$(LC_ALL=C nmcli -g "$field" connection show "$uuid" 2>/dev/null || true)
  printf '%s' "$value" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

capture_networkmanager_profiles() {
  local listing uuid type dns4 ignore4 dns6 ignore6 method4 method6 eap
  : >"$BACKUP_DIR/networkmanager-profiles.tsv"
  chmod 0600 "$BACKUP_DIR/networkmanager-profiles.tsv"
  listing=$(LC_ALL=C nmcli -t -f UUID,TYPE connection show 2>/dev/null) ||
    die 'cannot enumerate NetworkManager profiles'
  while IFS=: read -r uuid type; do
    [[ "$type" == '802-3-ethernet' || "$type" == '802-11-wireless' ]] || continue
    [[ "$uuid" =~ ^[0-9a-fA-F-]{36}$ ]] || continue
    dns4=$(nm_value "$uuid" ipv4.dns)
    ignore4=$(nm_value "$uuid" ipv4.ignore-auto-dns)
    dns6=$(nm_value "$uuid" ipv6.dns)
    ignore6=$(nm_value "$uuid" ipv6.ignore-auto-dns)
    method4=$(nm_value "$uuid" ipv4.method)
    method6=$(nm_value "$uuid" ipv6.method)
    eap=$(nm_value "$uuid" 802-1x.eap)
    printf '%s|%s|%s|%s|%s|%s|%s|%s\n' \
      "$uuid" "$(b64 "$dns4")" "$(b64 "$ignore4")" "$(b64 "$dns6")" \
      "$(b64 "$ignore6")" "$(b64 "$method4")" "$(b64 "$method6")" "$(b64 "$eap")" \
      >>"$BACKUP_DIR/networkmanager-profiles.tsv"
  done <<<"$listing"
}

capture_networkmanager_identity() {
  local listing uuid type field value
  local -a fields=(
    connection.stable-id
    ipv4.dhcp-client-id
    ipv4.dhcp-send-hostname
    ipv6.dhcp-send-hostname
    ipv6.dhcp-duid
    ipv6.addr-gen-mode
    ipv6.ip6-privacy
  )
  : >"$BACKUP_DIR/networkmanager-identity.tsv"
  chmod 0600 "$BACKUP_DIR/networkmanager-identity.tsv"
  ((FORCE_PROFILE_IDENTITY)) || return 0
  listing=$(LC_ALL=C nmcli -t -f UUID,TYPE connection show 2>/dev/null) ||
    die 'cannot enumerate NetworkManager profiles'
  while IFS=: read -r uuid type; do
    [[ "$type" == '802-3-ethernet' || "$type" == '802-11-wireless' ]] || continue
    [[ "$uuid" =~ ^[0-9a-fA-F-]{36}$ ]] || continue
    case "$type" in
      802-3-ethernet) fields+=(ethernet.cloned-mac-address) ;;
      802-11-wireless) fields+=(wifi.cloned-mac-address) ;;
    esac
    for field in "${fields[@]}"; do
      value=$(nm_value "$uuid" "$field")
      printf '%s|%s|%s\n' "$uuid" "$field" "$(b64 "$value")" \
        >>"$BACKUP_DIR/networkmanager-identity.tsv"
    done
    # Keep the per-type array from accumulating MAC fields across profiles.
    fields=(
      connection.stable-id
      ipv4.dhcp-client-id
      ipv4.dhcp-send-hostname
      ipv6.dhcp-send-hostname
      ipv6.dhcp-duid
      ipv6.addr-gen-mode
      ipv6.ip6-privacy
    )
  done <<<"$listing"
}

modify_networkmanager_profiles() {
  local file="$BACKUP_DIR/networkmanager-profiles.tsv"
  local uuid dns4_b64 ignore4_b64 dns6_b64 ignore6_b64 method4_b64 method6_b64 eap_b64
  local dns4 ignore4 dns6 ignore6 method4 method6 eap type
  report_section 'NetworkManager profiles'
  [[ -f "$file" ]] || return 0
  while IFS='|' read -r uuid dns4_b64 ignore4_b64 dns6_b64 ignore6_b64 \
    method4_b64 method6_b64 eap_b64; do
    [[ -n "$uuid" ]] || continue
    [[ "$uuid" =~ ^[0-9a-fA-F-]{36}$ ]] || {
      warn "ignoring invalid NetworkManager UUID: $uuid"
      continue
    }
    dns4=$(unb64 "$dns4_b64" 2>/dev/null || true)
    ignore4=$(unb64 "$ignore4_b64" 2>/dev/null || true)
    dns6=$(unb64 "$dns6_b64" 2>/dev/null || true)
    ignore6=$(unb64 "$ignore6_b64" 2>/dev/null || true)
    method4=$(unb64 "$method4_b64" 2>/dev/null || true)
    method6=$(unb64 "$method6_b64" 2>/dev/null || true)
    eap=$(unb64 "$eap_b64" 2>/dev/null || true)
    if [[ -n "$eap" ]]; then
      warn "skipping 802.1X profile $uuid: clearing DNS could break authentication"
      report_line 'skipped' "802.1X profile $uuid left unchanged"
      continue
    fi
    if [[ "$method4" == 'manual' || "$method6" == 'manual' ]]; then
      if ((FORCE_PROFILE_DNS == 0)); then
        warn "skipping static profile $uuid: use --force-profile-dns to clear its DNS"
        report_line 'skipped' "static profile $uuid left unchanged"
        continue
      fi
      warn "clearing static DNS on profile $uuid because --force-profile-dns was used"
    fi
    if ! nmcli connection modify "$uuid" \
      ipv4.ignore-auto-dns yes ipv6.ignore-auto-dns yes; then
      warn "could not set ignore-auto-dns on profile $uuid"
      continue
    fi
    if [[ "$method4" != 'manual' && "$method6" != 'manual' ]] || ((FORCE_PROFILE_DNS)); then
      if ! nmcli connection modify "$uuid" ipv4.dns '' ipv6.dns ''; then
        warn "could not clear per-profile DNS on $uuid"
      fi
    fi
    type=$(LC_ALL=C nmcli -g connection.type connection show "$uuid" 2>/dev/null || true)
    if [[ -n "$type" ]] && ((FORCE_PROFILE_IDENTITY)); then
      case "$type" in
        802-3-ethernet)
          nmcli connection modify "$uuid" ethernet.cloned-mac-address stable || true
          ;;
        802-11-wireless)
          nmcli connection modify "$uuid" wifi.cloned-mac-address stable || true
          ;;
      esac
      # shellcheck disable=SC2016
      nmcli connection modify "$uuid" \
        connection.stable-id '${CONNECTION}/${BOOT}' \
        ipv4.dhcp-client-id stable \
        ipv4.dhcp-send-hostname no \
        ipv6.dhcp-send-hostname no \
        ipv6.dhcp-duid ll \
        ipv6.addr-gen-mode stable-privacy \
        ipv6.ip6-privacy 2 || warn "could not force identity on profile $uuid"
    fi
  done <"$file"
}

restore_networkmanager_profiles() {
  local file="$BACKUP_DIR/networkmanager-profiles.tsv"
  local uuid dns4_b64 ignore4_b64 dns6_b64 ignore6_b64 method4_b64 method6_b64 eap_b64
  local dns4 ignore4 dns6 ignore6
  [[ -f "$file" ]] || {
    warn 'No saved NetworkManager profile state; skipping profile restore.'
    return 0
  }
  command -v nmcli >/dev/null 2>&1 || {
    warn 'nmcli is unavailable; cannot restore per-profile DNS values.'
    return 0
  }
  while IFS='|' read -r uuid dns4_b64 ignore4_b64 dns6_b64 ignore6_b64 \
    method4_b64 method6_b64 eap_b64; do
    [[ -n "$uuid" ]] || continue
    [[ "$uuid" =~ ^[0-9a-fA-F-]{36}$ ]] ||
      die "invalid UUID in profile backup: $uuid"
    dns4=$(unb64 "$dns4_b64") || die "invalid base64 DNS4 value for $uuid"
    ignore4=$(unb64 "$ignore4_b64") || die "invalid base64 IPv4 policy for $uuid"
    dns6=$(unb64 "$dns6_b64") || die "invalid base64 DNS6 value for $uuid"
    ignore6=$(unb64 "$ignore6_b64") || die "invalid base64 IPv6 policy for $uuid"
    run nmcli connection modify "$uuid" \
      ipv4.dns "$dns4" ipv4.ignore-auto-dns "$ignore4" \
      ipv6.dns "$dns6" ipv6.ignore-auto-dns "$ignore6" ||
      warn "could not restore NetworkManager profile $uuid"
  done <"$file"
}

restore_networkmanager_identity() {
  local file="$BACKUP_DIR/networkmanager-identity.tsv"
  local uuid field value_b64 value
  [[ -f "$file" ]] || return 0
  command -v nmcli >/dev/null 2>&1 || {
    warn 'nmcli is unavailable; cannot restore per-profile identity values.'
    return 0
  }
  while IFS='|' read -r uuid field value_b64; do
    [[ -n "$uuid" ]] || continue
    [[ "$uuid" =~ ^[0-9a-fA-F-]{36}$ ]] ||
      die "invalid UUID in identity backup: $uuid"
    case "$field" in
      connection.stable-id | ethernet.cloned-mac-address | wifi.cloned-mac-address | \
        ipv4.dhcp-client-id | ipv4.dhcp-send-hostname | ipv6.dhcp-send-hostname | \
        ipv6.dhcp-duid | ipv6.addr-gen-mode | ipv6.ip6-privacy) ;;
      *) die "unexpected NetworkManager field in identity backup: $field" ;;
    esac
    value=$(unb64 "$value_b64") || die "invalid base64 identity value for $uuid/$field"
    run nmcli connection modify "$uuid" "$field" "$value" ||
      warn "could not restore $field on profile $uuid"
  done <"$file"
}

verify_networkmanager() {
  local config=/etc/NetworkManager/conf.d/00-moriarty-identity.conf
  local listing uuid type dns4 method4 ignore4
  report_section 'NetworkManager'
  if [[ -f "$config" ]]; then
    if grep -Fq "connection.stable-id=\${CONNECTION}/\${BOOT}" "$config" &&
      grep -Fq 'cloned-mac-address=stable' "$config"; then
      report_line 'applied' 'per-boot stable identity defaults are present'
    else
      record_status 'mismatch' "$config does not contain the expected identity policy"
    fi
  else
    record_status 'missing' "$config is missing"
  fi
  if command -v NetworkManager >/dev/null 2>&1; then
    if NetworkManager --print-config 2>/dev/null |
      grep -Fq "connection.stable-id=\${CONNECTION}/\${BOOT}"; then
      report_line 'applied' 'NetworkManager merged configuration contains stable-id'
    else
      record_status 'mismatch' 'NetworkManager merged configuration does not show stable-id'
    fi
  fi
  listing=$(LC_ALL=C nmcli -t -f UUID,TYPE connection show 2>/dev/null || true)
  while IFS=: read -r uuid type; do
    [[ "$type" == '802-3-ethernet' || "$type" == '802-11-wireless' ]] || continue
    [[ "$uuid" =~ ^[0-9a-fA-F-]{36}$ ]] || continue
    method4=$(nm_value "$uuid" ipv4.method)
    dns4=$(nm_value "$uuid" ipv4.dns)
    ignore4=$(nm_value "$uuid" ipv4.ignore-auto-dns)
    if [[ "$method4" != 'manual' && -n "$dns4" ]]; then
      record_status 'mismatch' "profile $uuid still carries DNS '$dns4'"
    elif [[ "$ignore4" != 'yes' ]]; then
      report_line 'pending' "profile $uuid does not set ipv4.ignore-auto-dns=yes"
    else
      report_line 'applied' "profile $uuid has profile DNS disabled"
    fi
  done <<<"$listing"
  report_line 'pending-reboot' 'cloned MAC, DHCP client-id and IPv6 identity rotate after reboot'
}

# ---------------------------------------------------------------------------
# DNS
# ---------------------------------------------------------------------------

write_dnscrypt_config() {
  write_file /etc/dnscrypt-proxy/dnscrypt-proxy.toml <<'EOF'
# Moriarty: local encrypted resolver.
# server_names is an explicit, pinned list. The require_* filters do not apply
# to explicit names, so Moriarty verifies the metadata with dnscrypt-proxy -list
# before switching the host resolver.
listen_addresses = ['127.0.0.1:53']
server_names = ['quad9-dnscrypt-ip4-nofilter-pri', 'dns.digitale-gesellschaft.ch']

require_dnssec = true
require_nolog = true
require_nofilter = true
doh_servers = true
dnscrypt_servers = true
ipv4_servers = true
ipv6_servers = false

cache = true
cache_size = 4096
cache_min_ttl = 2400

# Bootstrap is plain DNS and is used only to fetch the signed resolver list or
# to locate DoH endpoints. User queries are sent through the encrypted servers.
bootstrap_resolvers = ['9.9.9.9:53', '149.112.112.112:53']
ignore_system_dns = true
netprobe_timeout = 30
block_unqualified = true
block_undelegated = true

[sources.public-resolvers]
urls = ['https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md', 'https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md']
cache_file = '/var/cache/dnscrypt-proxy/public-resolvers.md'
minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
refresh_delay = 72
EOF
}

verify_resolver_metadata() {
  local config=/etc/dnscrypt-proxy/dnscrypt-proxy.toml
  local temporary list name failed=0
  [[ -f "$config" ]] || {
    record_status 'missing' "$config is missing"
    return 0
  }
  command -v timeout >/dev/null 2>&1 || {
    warn 'timeout is unavailable; cannot verify resolver metadata'
    return 0
  }
  temporary=$(mktemp /tmp/moriarty-resolvers.XXXXXX)
  sed '/^[[:space:]]*server_names[[:space:]]*=/d' "$config" >"$temporary"
  if ! list=$(timeout 30 dnscrypt-proxy -list -config "$temporary" 2>/dev/null); then
    warn 'could not enumerate filtered resolvers; metadata check skipped'
    report_line 'warning' 'resolver metadata could not be verified'
    rm -f -- "$temporary"
    return 0
  fi
  report_section 'resolver metadata'
  for name in quad9-dnscrypt-ip4-nofilter-pri dns.digitale-gesellschaft.ch; do
    if grep -qxF -- "$name" <<<"$list"; then
      report_line 'applied' "$name satisfies DNSSEC/no-log/no-filter filters"
    else
      record_status 'mismatch' "$name does not satisfy the configured resolver filters"
      failed=1
    fi
  done
  rm -f -- "$temporary"
  ((failed == 0)) ||
    die 'a pinned resolver no longer satisfies the security filters; review server_names'
}

start_dnscrypt() {
  dnscrypt-proxy -check -config /etc/dnscrypt-proxy/dnscrypt-proxy.toml >/dev/null ||
    die 'dnscrypt-proxy rejected its configuration'
  systemctl disable --now dnscrypt-proxy.socket >/dev/null 2>&1 ||
    warn 'could not disable dnscrypt-proxy.socket (it may not be installed)'
  systemctl enable dnscrypt-proxy.service ||
    die 'could not enable dnscrypt-proxy.service'
  systemctl restart dnscrypt-proxy.service ||
    die 'dnscrypt-proxy failed to start; run journalctl -u dnscrypt-proxy'
  for _ in {1..15}; do
    if dig @127.0.0.1 example.com +short +time=2 +tries=1 2>/dev/null | grep -q .; then
      ok 'DNSCrypt answers locally'
      return 0
    fi
    sleep 2
  done
  die 'DNSCrypt did not answer on 127.0.0.1:53; resolver routing was not changed'
}

write_resolved_config() {
  write_file /etc/systemd/resolved.conf.d/99-moriarty-dns.conf <<'EOF'
# Moriarty: systemd-resolved is a client of the local dnscrypt-proxy.
# DNSSEC=no is intentional: validation is performed by the encrypted upstream
# resolver, not again by resolved. FallbackDNS is empty to avoid plaintext
# leaks if dnscrypt-proxy is unavailable.
[Resolve]
DNS=127.0.0.1
FallbackDNS=
LLMNR=no
MulticastDNS=no
DNSSEC=no
DNSOverTLS=no
CacheFromLocalhost=no
EOF
}

write_resolv_conf() {
  if [[ -L /etc/resolv.conf ]]; then
    warn '/etc/resolv.conf is a symlink; Moriarty replaces the link, not its target'
  fi
  write_file /etc/resolv.conf <<'EOF'
# Generated by Moriarty. Use moriarty-restore.sh to return to the prior resolver.
nameserver 127.0.0.1
options edns0
EOF
}

dns_is_loopback() {
  local value=$1
  value=${value%%#*}
  value=${value%:53}
  value=${value#[}
  value=${value%]}
  [[ "$value" == '127.0.0.1' || "$value" == '::1' ]]
}

verify_dns() {
  local line token
  report_section 'DNS'
  if ! grep -Eq '^[[:space:]]*nameserver[[:space:]]+127\.0\.0\.1$' /etc/resolv.conf; then
    record_status 'mismatch' '/etc/resolv.conf does not point to 127.0.0.1'
  else
    report_line 'applied' '/etc/resolv.conf points to 127.0.0.1'
  fi
  if systemctl is-active --quiet dnscrypt-proxy.service; then
    report_line 'applied' 'dnscrypt-proxy.service is active'
  else
    record_status 'mismatch' 'dnscrypt-proxy.service is not active'
  fi
  if dig @127.0.0.1 example.com +time=3 +tries=1 +short 2>/dev/null | grep -q .; then
    report_line 'applied' 'direct DNSCrypt query succeeded'
  else
    record_status 'mismatch' 'direct DNSCrypt query failed'
  fi
  if dig example.com +time=3 +tries=1 +short 2>/dev/null | grep -q .; then
    report_line 'applied' 'system resolver query succeeded'
  else
    record_status 'mismatch' 'system resolver query failed'
  fi
  if getent ahosts example.com >/dev/null 2>&1; then
    report_line 'applied' 'NSS/getent resolution succeeded'
  else
    record_status 'mismatch' 'NSS/getent resolution failed'
  fi
  if command -v resolvectl >/dev/null 2>&1; then
    while IFS= read -r line; do
      [[ "$line" == *:* ]] || continue
      for token in ${line#*:}; do
        token=$(printf '%s' "$token" | tr -d '[:space:]')
        [[ -n "$token" ]] || continue
        if ! dns_is_loopback "$token"; then
          record_status 'mismatch' "systemd-resolved still lists foreign DNS server $token"
        fi
      done
    done < <(resolvectl dns 2>/dev/null || true)
  fi
}

# ---------------------------------------------------------------------------
# Avahi and UFW
# ---------------------------------------------------------------------------

set_avahi_publishing_off() {
  local file=/etc/avahi/avahi-daemon.conf temporary
  [[ -f "$file" ]] || {
    warn 'Avahi is not installed; skipping its configuration'
    return 0
  }
  backup_path "$file"
  temporary=$(mktemp /etc/avahi/.avahi-daemon.conf.moriarty.XXXXXX) ||
    die 'cannot create Avahi temporary file'
  awk '
    BEGIN { section=""; in_publish=0; publish_seen=0; key_seen=0 }
    /^\[[^]]+\][[:space:]]*$/ {
      if (in_publish && !key_seen) { print "disable-publishing=yes"; key_seen=1 }
      section=$0
      sub(/^\[/, "", section)
      sub(/\].*$/, "", section)
      section=tolower(section)
      in_publish=(section == "publish")
      if (in_publish) publish_seen=1
      print
      next
    }
    {
      if ($0 ~ /^[[:space:]]*#?[[:space:]]*disable-publishing[[:space:]]*=/) {
        # Drop the key everywhere else; it is only valid in [publish].
        if (in_publish) {
          if (!key_seen) print "disable-publishing=yes"
          key_seen=1
        }
        next
      }
      print
    }
    END {
      if (in_publish && !key_seen) print "disable-publishing=yes"
      if (!publish_seen) print "\n[publish]\ndisable-publishing=yes"
    }
  ' "$file" >"$temporary" || {
    rm -f -- "$temporary"
    die 'cannot update Avahi configuration'
  }
  chmod --reference="$file" "$temporary"
  chown --reference="$file" "$temporary" 2>/dev/null || true
  sync -- "$temporary" 2>/dev/null || true
  mv -fT -- "$temporary" "$file"
}

set_ufw_sysctl() {
  local key=$1 value=$2 file=/etc/ufw/sysctl.conf temporary output
  [[ -f "$file" ]] || return 0
  backup_path "$file"
  temporary=$(mktemp /etc/ufw/.sysctl.conf.moriarty.XXXXXX) ||
    die 'cannot create UFW sysctl temporary file'
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
  ' "$file") || {
    rm -f -- "$temporary"
    die 'cannot update UFW sysctl settings'
  }
  printf '%s\n' "$output" >"$temporary"
  chmod --reference="$file" "$temporary"
  chown --reference="$file" "$temporary" 2>/dev/null || true
  sync -- "$temporary" 2>/dev/null || true
  mv -fT -- "$temporary" "$file"
}

# ---------------------------------------------------------------------------
# Backup metadata and rollback
# ---------------------------------------------------------------------------

create_backup_dir() {
  BACKUP_DIR=$(mktemp -d "/root/moriarty-backup.$(date +%Y%m%d_%H%M%S).XXXXXX") ||
    die 'cannot create backup directory'
  chmod 0700 "$BACKUP_DIR"
  MANIFEST="$BACKUP_DIR/MANIFEST"
  printf '# moriarty-manifest-v2\n' >"$MANIFEST"
  chmod 0600 "$MANIFEST"
  REPORT_FILE="$BACKUP_DIR/report.txt"
  : >"$REPORT_FILE"
  chmod 0600 "$REPORT_FILE"
  cat >"$BACKUP_DIR/META" <<EOF
version	$VERSION
profile	$PROFILE
created	$(date -u +%Y-%m-%dT%H:%M:%SZ)
hostname	$(hostname 2>/dev/null || printf 'unknown')
kernel	$(uname -r)
EOF
  chmod 0600 "$BACKUP_DIR/META"
}

capture_service_state() {
  local unit enabled active
  local -a units=(
    dnscrypt-proxy.service dnscrypt-proxy.socket
    NetworkManager.service systemd-resolved.service avahi-daemon.service
  )
  : >"$BACKUP_DIR/systemd-units.tsv"
  chmod 0600 "$BACKUP_DIR/systemd-units.tsv"
  for unit in "${units[@]}"; do
    enabled=$(systemctl is-enabled "$unit" 2>/dev/null || true)
    active=$(systemctl is-active "$unit" 2>/dev/null || true)
    [[ -n "$enabled" ]] || enabled=not-found
    [[ -n "$active" ]] || active=inactive
    printf '%s\t%s\t%s\n' "$unit" "$enabled" "$active" >>"$BACKUP_DIR/systemd-units.tsv"
  done
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
    value=$(unb64 "$encoded") || die "invalid sysctl snapshot for $key"
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

rollback_changes() {
  local status=1
  ((CHANGES_STARTED)) || return 0
  CHANGES_STARTED=0
  warn 'A phase failed; rolling back configuration changes from this run.'
  if [[ -f "$MANIFEST" ]]; then
    while IFS=$'\t' read -r action path _; do
      case "$action" in
        modified | created) ;;
        *) continue ;;
      esac
      if ! restore_one_path "$path"; then
        warn "could not roll back $path"
        status=0
      fi
    done < <(tac -- "$MANIFEST")
  fi
  restore_networkmanager_profiles || status=0
  restore_networkmanager_identity || status=0
  systemctl daemon-reload >/dev/null 2>&1 || true
  if command -v sysctl >/dev/null 2>&1; then
    sysctl --system >/dev/null 2>&1 || true
  fi
  restore_sysctl_runtime || status=0
  systemctl try-restart NetworkManager.service >/dev/null 2>&1 || true
  systemctl try-restart systemd-resolved.service >/dev/null 2>&1 || true
  restore_systemd_states || status=0
  ((status == 1)) && ok 'Rollback completed; installed packages remain installed.'
  return 0
}

on_exit() {
  local status=$?
  trap - EXIT
  if ((status != 0)); then
    if ((ROLLBACK_ON_ERROR == 1 && CHANGES_STARTED == 1)); then
      rollback_changes || warn 'Rollback did not complete cleanly.'
    fi
    if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
      printf '\nBackup retained at: %s\n' "$BACKUP_DIR" >&2
      printf 'Full restore: sudo ./moriarty-restore.sh %q\n' "$BACKUP_DIR" >&2
      printf 'Report: %s\n' "$REPORT_FILE" >&2
    fi
  fi
  exit "$status"
}
trap on_exit EXIT

# ---------------------------------------------------------------------------
# Main phases
# ---------------------------------------------------------------------------

print_summary() {
  printf '\n%sSummary%s\n' "$BOLD" "$RESET"
  printf '  sysctl applied:     %s\n' "$SYSCTL_APPLIED"
  printf '  sysctl unsupported: %s\n' "$SYSCTL_UNSUPPORTED"
  printf '  sysctl rejected:    %s\n' "$SYSCTL_REJECTED"
  printf '  sysctl mismatch:    %s\n' "$SYSCTL_MISMATCH"
  printf '  warnings:           %s\n' "$WARNINGS"
}

dry_run_plan() {
  section "Moriarty $VERSION dry-run (profile: $PROFILE)"
  log 'The following components would be processed:'
  log '  [1/7] dependencies: dnscrypt-proxy + bind (unless --skip-dns)'
  log '  [2/7] sysctl: apply and verify per-key hardening + performance profiles'
  log '  [3/7] modules: modprobe install /bin/false policy (unless --skip-modules)'
  log '  [4/7] NetworkManager: stable per-boot identity and profile DNS policy'
  log '  [5/7] DNS: dnscrypt-proxy on 127.0.0.1:53, metadata check, resolver switch'
  log '  [6/7] resolved/Avahi/UFW: drop-in, publishing, optional sysctl alignment'
  log '  [7/7] verification: sysctl values, resolver paths, NSS and report'
  log ''
  log 'No changes were made.'
}

run_check() {
  local candidate performance
  candidate=$(mktemp /tmp/moriarty-check-sysctl.XXXXXX)
  performance=$(mktemp /tmp/moriarty-check-performance.XXXXXX)
  REPORT_FILE=$(mktemp /tmp/moriarty-check-report.XXXXXX)
  build_sysctl_candidate "$candidate"
  build_performance_candidate "$performance" >/dev/null 2>&1 || true
  report_section 'Moriarty check'
  report_line 'info' "version=$VERSION profile=$PROFILE"
  check_sysctl_candidate "$candidate"

  report_section 'files'
  for path in \
    /etc/sysctl.d/99-moriarty-hardening.conf \
    /etc/sysctl.d/99-moriarty-performance.conf \
    /etc/modprobe.d/99-moriarty-blacklist.conf \
    /etc/NetworkManager/conf.d/00-moriarty-identity.conf \
    /etc/NetworkManager/conf.d/90-dns-none.conf \
    /etc/dnscrypt-proxy/dnscrypt-proxy.toml \
    /etc/systemd/resolved.conf.d/99-moriarty-dns.conf; do
    if [[ -f "$path" ]]; then
      report_line 'applied' "$path exists"
    else
      report_line 'missing' "$path is missing"
    fi
  done
  if grep -Eq '^[[:space:]]*nameserver[[:space:]]+127\.0\.0\.1$' /etc/resolv.conf 2>/dev/null; then
    report_line 'applied' '/etc/resolv.conf points to 127.0.0.1'
  else
    record_status 'mismatch' '/etc/resolv.conf does not point to 127.0.0.1'
  fi

  if ! ((SKIP_NETWORK)); then
    verify_networkmanager
  fi
  if ! ((SKIP_MODULES)); then
    verify_module_policy /etc/modprobe.d/99-moriarty-blacklist.conf
  fi
  if ! ((SKIP_DNS)); then
    verify_dns
  fi

  print_summary
  if ((SYSCTL_FAILURES > 0)); then
    warn "check found $SYSCTL_FAILURES mandatory sysctl failures"
    cp "$REPORT_FILE" /tmp/moriarty-check-report.txt 2>/dev/null || true
    log 'Full report copied to /tmp/moriarty-check-report.txt'
    rm -f -- "$candidate" "$performance"
    return 1
  fi
  ok 'check completed without mandatory sysctl failures'
  cp "$REPORT_FILE" /tmp/moriarty-check-report.txt 2>/dev/null || true
  log 'Full report copied to /tmp/moriarty-check-report.txt'
  rm -f -- "$candidate" "$performance"
  return 0
}

main() {
  local candidate performance
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
      --check) CHECK_ONLY=1 ;;
      -y | --yes) ASSUME_YES=1 ;;
      --profile)
        (($# >= 2)) || die '--profile requires an argument'
        PROFILE=$2
        shift
        ;;
      --profile=*) PROFILE=${1#*=} ;;
      --skip-modules) SKIP_MODULES=1 ;;
      --skip-network) SKIP_NETWORK=1 ;;
      --skip-dns) SKIP_DNS=1 ;;
      --skip-avahi) SKIP_AVAHI=1 ;;
      --skip-ufw) SKIP_UFW=1 ;;
      --force-profile-dns) FORCE_PROFILE_DNS=1 ;;
      --force-profile-identity) FORCE_PROFILE_IDENTITY=1 ;;
      --no-rollback) ROLLBACK_ON_ERROR=0 ;;
      --no-color) USE_COLOR=0 ;;
      --)
        shift
        break
        ;;
      -*) die "unknown option: $1 (try --help)" ;;
      *) die "unexpected argument: $1 (try --help)" ;;
    esac
    shift
  done

  case "$PROFILE" in
    balanced | strict) ;;
    *) die "invalid profile: $PROFILE (expected balanced or strict)" ;;
  esac
  if ((USE_COLOR == 0)); then
    RED=''
    GREEN=''
    YELLOW=''
    BOLD=''
    RESET=''
  fi

  if ((CHECK_ONLY && DRY_RUN)); then
    die 'choose either --check or --dry-run, not both'
  fi
  if ((CHECK_ONLY)); then
    run_check
    exit $?
  fi
  if ((DRY_RUN)); then
    dry_run_plan
    exit 0
  fi

  ((EUID == 0)) || die "run as root: sudo bash $PROG"
  [[ -r /etc/os-release ]] || die '/etc/os-release is missing'
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == arch ]] || [[ " ${ID_LIKE:-} " == *"arch"* ]] ||
    warn 'This is not a detected Arch Linux system; continuing at your own risk.'

  for cmd in pacman systemctl sysctl sha256sum base64 flock realpath stat mktemp install sync awk sed grep tac; do
    require_command "$cmd"
  done
  if ! ((SKIP_NETWORK)); then
    require_command nmcli
  fi
  if ! ((SKIP_MODULES)); then
    require_command modprobe
  fi
  if ! ((SKIP_DNS)); then
    require_command timeout
  fi

  if ((ASSUME_YES == 0)); then
    [[ -t 0 ]] || die 'non-interactive shell: use --yes'
    printf '%sThis modifies /etc, kernel settings, NetworkManager and DNS.%s\n' \
      "$YELLOW" "$RESET"
    read -r -p 'Continue? [y/N] ' answer
    [[ "$answer" =~ ^([yY]|[yY][eE][sS])$ ]] || {
      log 'Aborted.'
      exit 1
    }
  fi

  install -d -m 0755 /run/lock
  exec 9>"$LOCK_FILE"
  flock -n 9 || die 'another Moriarty process is already running'

  create_backup_dir
  section "Moriarty $VERSION (profile: $PROFILE)"
  log "Backup and report: $BACKUP_DIR"

  candidate="$BACKUP_DIR/sysctl-candidate.conf"
  performance="$BACKUP_DIR/performance-candidate.conf"
  build_sysctl_candidate "$candidate"
  ensure_bbr_module || true
  build_performance_candidate "$performance"

  capture_sysctl_state "$candidate" "$performance"
  capture_service_state
  if ! ((SKIP_NETWORK)); then
    capture_networkmanager_profiles
    capture_networkmanager_identity
  fi

  log '[1/7] Dependencies'
  if ((SKIP_DNS)); then
    ok 'DNS phase skipped; no packages installed for it'
  else
    pacman -S --needed --noconfirm dnscrypt-proxy bind ||
      die 'dependency installation failed; check network and pacman mirrors'
    require_command dnscrypt-proxy
    require_command dig
    ok 'dnscrypt-proxy and bind are installed'
  fi

  CHANGES_STARTED=1
  report_section 'environment'
  report_line 'info' "version=$VERSION profile=$PROFILE kernel=$(uname -r)"
  report_line 'info' "backup=$BACKUP_DIR"

  log '[2/7] Applying sysctl hardening and performance profiles'
  apply_sysctl_profile "$candidate" /etc/sysctl.d/99-moriarty-hardening.conf 'hardening'
  apply_performance_profile "$performance" /etc/sysctl.d/99-moriarty-performance.conf
  load_and_verify_sysctl \
    /etc/sysctl.d/99-moriarty-hardening.conf \
    /etc/sysctl.d/99-moriarty-performance.conf

  log '[3/7] Configuring module blacklist'
  if ((SKIP_MODULES)); then
    ok 'module policy skipped'
  else
    remove_managed_path /etc/modprobe.d/blacklist-obscure.conf
    write_module_policy /etc/modprobe.d/99-moriarty-blacklist.conf
    verify_module_policy /etc/modprobe.d/99-moriarty-blacklist.conf
    ok 'module policy written (full effect may require reboot)'
  fi

  log '[4/7] Configuring NetworkManager identity policy'
  if ((SKIP_NETWORK)); then
    ok 'NetworkManager phase skipped'
  else
    remove_managed_path /etc/NetworkManager/conf.d/00-mac-ip-randomize.conf
    write_file /etc/NetworkManager/conf.d/00-moriarty-identity.conf <<'EOF'
[device]
wifi.scan-rand-mac-address=yes

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
ipv6.ip6-privacy=2
EOF
    write_file /etc/NetworkManager/conf.d/90-dns-none.conf <<'EOF'
[main]
dns=none
EOF
    modify_networkmanager_profiles
    nmcli general reload || die 'NetworkManager could not reload its configuration'
    verify_networkmanager
    ok 'NetworkManager defaults and profiles updated'
  fi

  log '[5/7] Configuring encrypted DNS'
  if ((SKIP_DNS)); then
    ok 'DNS phase skipped'
  else
    write_dnscrypt_config
    verify_resolver_metadata
    start_dnscrypt
    write_resolved_config
    systemctl try-restart systemd-resolved >/dev/null 2>&1 ||
      warn 'systemd-resolved is not active; its configuration will apply when started'
    write_resolv_conf
    if ! ((SKIP_NETWORK)); then
      nmcli general reload || die 'NetworkManager failed to reload after DNS routing changed'
    fi
    ok 'DNS routing switched to dnscrypt-proxy'
  fi

  log '[6/7] Configuring Avahi and UFW sysctl'
  if ((SKIP_AVAHI)); then
    ok 'Avahi phase skipped'
  else
    set_avahi_publishing_off
    if [[ -f /etc/avahi/avahi-daemon.conf ]] &&
      { systemctl is-active --quiet avahi-daemon ||
        systemctl is-enabled --quiet avahi-daemon; }; then
      # Clear a start-limit-hit left behind by an older, invalid configuration.
      systemctl reset-failed avahi-daemon.service avahi-daemon.socket >/dev/null 2>&1 || true
      systemctl restart avahi-daemon >/dev/null 2>&1 ||
        warn 'Avahi config saved, but avahi-daemon could not be restarted'
    fi
  fi
  if ((SKIP_UFW)); then
    ok 'UFW phase skipped'
  else
    if [[ -f /etc/ufw/sysctl.conf ]]; then
      set_ufw_sysctl net/ipv4/conf/all/rp_filter 2
      set_ufw_sysctl net/ipv4/conf/default/rp_filter 2
      set_ufw_sysctl net/ipv4/conf/all/log_martians 1
      set_ufw_sysctl net/ipv4/conf/default/log_martians 1
      ok 'UFW sysctl values aligned'
    else
      warn 'UFW sysctl file not found; no UFW firewall rules were installed or enabled'
    fi
  fi

  log '[7/7] Verifying effective configuration'
  if ! ((SKIP_DNS)); then
    verify_dns
  fi
  print_summary
  if ((SYSCTL_FAILURES > 0)); then
    die "mandatory sysctl settings failed; review $REPORT_FILE"
  fi

  CHANGES_STARTED=0
  report_section 'result'
  report_line 'success' 'Moriarty completed'
  printf '\n%sCOMPLETE%s\n' "$GREEN" "$RESET"
  printf 'Profile: %s\n' "$PROFILE"
  printf 'Backup: %s\n' "$BACKUP_DIR"
  printf 'Report: %s\n' "$REPORT_FILE"
  printf 'Restore: sudo ./moriarty-restore.sh %q\n' "$BACKUP_DIR"
  printf 'Reboot required so the new MAC, DHCP client-id and module policy take effect.\n'
  printf 'Packages installed by Moriarty are intentionally left installed by restore.\n'
}

main "$@"
