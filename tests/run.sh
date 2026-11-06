#!/usr/bin/env bash
# Regression tests for Moriarty. Designed to run as root inside a container.
set -euo pipefail

PROG_DIR=$(cd -- "$(dirname -- "$0")/.." && pwd)
PASS=0
FAIL=0

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/moriarty-tests.XXXXXX")
cleanup() { rm -rf -- "$WORK_DIR"; }
trap cleanup EXIT

pass() {
  printf 'PASS: %s\n' "$*"
  PASS=$((PASS + 1))
}
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  FAIL=$((FAIL + 1))
}

assert_exit() {
  local expected=$1
  shift
  set +e
  "$@" >"$WORK_DIR/test.out" 2>&1
  local status=$?
  set -e
  if [[ "$status" -eq "$expected" ]]; then
    return 0
  fi
  printf 'unexpected exit %s, expected %s: %s\n' "$status" "$expected" "$*" >&2
  cat "$WORK_DIR/test.out" >&2
  return 1
}

run() {
  "$@"
}

run_root() {
  # SKIP when not root.
  [[ ${EUID:-$(id -u)} -eq 0 ]] || {
    log "SKIP (not root): $*"
    return 0
  }
  "$@"
}

log() { printf '%s\n' "$*"; }

# Basic CLI behavior (root not required).
assert_exit 0 "$PROG_DIR/moriarty.sh" --help
pass 'help exits 0'
assert_exit 0 "$PROG_DIR/moriarty.sh" --version
pass 'version exits 0'
assert_exit 0 "$PROG_DIR/moriarty.sh" --dry-run
pass 'dry-run exits 0'
assert_exit 1 "$PROG_DIR/moriarty.sh" --bogus-option
pass 'unknown option exits 1'

# dry-run must reflect component skips instead of advertising disabled phases.
"$PROG_DIR/moriarty.sh" --dry-run --yes --no-color --skip-dns \
  >"$WORK_DIR/dry-skip-dns.out" 2>&1 || true
if grep -q 'skipped by --skip-dns' "$WORK_DIR/dry-skip-dns.out" &&
  ! grep -q '90-dns-none' "$WORK_DIR/dry-skip-dns.out"; then
  pass 'dry-run reports --skip-dns'
else
  fail 'dry-run reports --skip-dns'
fi

# Apply and restore must share one lock.
apply_lock=$(grep -m1 '^LOCK_FILE=' "$PROG_DIR/moriarty.sh" | cut -d= -f2-)
restore_lock=$(grep -m1 '^LOCK_FILE=' "$PROG_DIR/moriarty-restore.sh" | cut -d= -f2-)
if [[ -n "$apply_lock" && "$apply_lock" == "$restore_lock" ]]; then
  pass 'apply and restore share the same lock file'
else
  fail 'apply and restore share the same lock file'
fi

# The transaction must start before BBR writes its persistent file.
bbr_line=$(grep -n 'ensure_bbr_module || true' "$PROG_DIR/moriarty.sh" | tail -1 | cut -d: -f1)
tx_line=$(grep -n 'CHANGES_STARTED=1' "$PROG_DIR/moriarty.sh" | head -1 | cut -d: -f1)
if [[ -n "$bbr_line" && -n "$tx_line" && "$tx_line" -lt "$bbr_line" ]]; then
  pass 'transaction starts before ensure_bbr_module'
else
  fail 'transaction starts before ensure_bbr_module'
fi

# Resolver metadata verification must fail closed.
resolver_fn=$(awk '
  /^verify_resolver_metadata\(\) \{/ { capture = 1 }
  capture { print }
  capture && /^\}$/ { exit }
' "$PROG_DIR/moriarty.sh")
if grep -Fq 'metadata check skipped' <<<"$resolver_fn"; then
  fail 'resolver metadata verification fails closed'
elif ! grep -Fq 'die '"'"'could not enumerate resolver metadata' <<<"$resolver_fn"; then
  fail 'resolver metadata verification fails closed'
else
  pass 'resolver metadata verification fails closed'
fi

assert_exit 0 "$PROG_DIR/moriarty-restore.sh" --help
pass 'restore help exits 0'
assert_exit 0 "$PROG_DIR/moriarty-restore.sh" --list
pass 'restore list exits 0'

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  log 'Not root; skipping backup ownership and permission tests.'
  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
  [[ "$FAIL" -eq 0 ]]
  exit
fi

# Set up a synthetic, valid v2 backup.
backup=$(mktemp -d /root/moriarty-backup.TEST.XXXXXX)
chmod 0700 "$backup"
printf '# moriarty-manifest-v2\n' >"$backup/MANIFEST"
chmod 0600 "$backup/MANIFEST"
mkdir -p "$backup/etc/sysctl.d"
printf 'kernel.sysrq = 176\n' >"$backup/etc/sysctl.d/99-moriarty-hardening.conf"
chmod 0644 "$backup/etc/sysctl.d/99-moriarty-hardening.conf"
hash=$(sha256sum "$backup/etc/sysctl.d/99-moriarty-hardening.conf" | awk '{print $1}')
printf 'modified\t/etc/sysctl.d/99-moriarty-hardening.conf\t%s\n' "$hash" >>"$backup/MANIFEST"
chown root:root "$backup" "$backup/MANIFEST"
assert_exit 0 "$PROG_DIR/moriarty-restore.sh" --dry-run "$backup"
pass 'valid v2 manifest dry-run succeeds'

# Checksum mismatch is rejected.
cp "$backup/etc/sysctl.d/99-moriarty-hardening.conf" "$WORK_DIR/orig"
printf 'x' >>"$backup/etc/sysctl.d/99-moriarty-hardening.conf"
if assert_exit 1 "$PROG_DIR/moriarty-restore.sh" --dry-run "$backup"; then
  pass 'checksum mismatch is rejected'
else
  fail 'checksum mismatch is rejected'
fi
cp -p "$WORK_DIR/orig" "$backup/etc/sysctl.d/99-moriarty-hardening.conf"
hash=$(sha256sum "$backup/etc/sysctl.d/99-moriarty-hardening.conf" | awk '{print $1}')
# Rebuild manifest hash by replacing the last field.
awk -F '\t' -v OFS='\t' -v h="$hash" '
  $1 == "modified" && $2 == "/etc/sysctl.d/99-moriarty-hardening.conf" { $3 = h }
  { print }
' "$backup/MANIFEST" >"$WORK_DIR/MANIFEST.new"
cat "$WORK_DIR/MANIFEST.new" >"$backup/MANIFEST"

# Malicious manifest path is rejected.
bad_backup=$(mktemp -d /root/moriarty-backup.BAD.XXXXXX)
chmod 0700 "$bad_backup"
printf '# moriarty-manifest-v2\ncreated\t/etc/passwd\t-\n' >"$bad_backup/MANIFEST"
chmod 0600 "$bad_backup/MANIFEST"
chown root:root "$bad_backup" "$bad_backup/MANIFEST"
if assert_exit 1 "$PROG_DIR/moriarty-restore.sh" --dry-run "$bad_backup"; then
  pass 'disallowed manifest path is rejected'
else
  fail 'disallowed manifest path is rejected'
fi
rm -rf "$bad_backup"

# Symlinked backup directory is rejected.
link_backup=/root/moriarty-backup.LINK.XXXXXX
rm -rf "$link_backup"
ln -s "$backup" "$link_backup"
if assert_exit 1 "$PROG_DIR/moriarty-restore.sh" --dry-run "$link_backup"; then
  pass 'symlinked backup is rejected'
else
  fail 'symlinked backup is rejected'
fi
rm -f "$link_backup"

# World-readable backup is rejected.
chmod 0755 "$backup"
if assert_exit 1 "$PROG_DIR/moriarty-restore.sh" --dry-run "$backup"; then
  pass 'world-readable backup is rejected'
else
  fail 'world-readable backup is rejected'
fi
chmod 0700 "$backup"

rm -rf "$backup"
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
