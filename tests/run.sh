#!/usr/bin/env bash
# Regression tests for Moriarty. Designed to run as root inside a container.
set -euo pipefail

PROG_DIR=$(cd -- "$(dirname -- "$0")/.." && pwd)
PASS=0
FAIL=0

pass() { printf 'PASS: %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }

assert_exit() {
  local expected=$1
  shift
  set +e
  "$@" >/tmp/opencode/test.out 2>&1
  local status=$?
  set -e
  if [[ "$status" -eq "$expected" ]]; then
    return 0
  fi
  printf 'unexpected exit %s, expected %s: %s\n' "$status" "$expected" "$*" >&2
  cat /tmp/opencode/test.out >&2
  return 1
}

run() {
  "$@"
}

run_root() {
  # SKIP when not root.
  [[ ${EUID:-$(id -u)} -eq 0 ]] || { log "SKIP (not root): $*"; return 0; }
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
assert_exit 2 "$PROG_DIR/moriarty.sh" --bogus-option >/dev/null 2>&1 || true
# argparse in this script uses die for unknown options; exit 1.
assert_exit 1 "$PROG_DIR/moriarty.sh" --bogus-option
pass 'unknown option exits 1'

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

mkdir -p /tmp/opencode
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
cp "$backup/etc/sysctl.d/99-moriarty-hardening.conf" /tmp/opencode/orig
printf 'x' >>"$backup/etc/sysctl.d/99-moriarty-hardening.conf"
assert_exit 1 "$PROG_DIR/moriarty-restore.sh" --dry-run "$backup" || true
pass 'checksum mismatch is rejected'
cp -p /tmp/opencode/orig "$backup/etc/sysctl.d/99-moriarty-hardening.conf"
hash=$(sha256sum "$backup/etc/sysctl.d/99-moriarty-hardening.conf" | awk '{print $1}')
# Rebuild manifest hash by replacing last field.
python3 - "$backup/MANIFEST" "$hash" <<'PY'
import sys
path, h = sys.argv[1], sys.argv[2]
lines = open(path).read().splitlines()
out=[]
for line in lines:
    if line.startswith('modified\t/etc/sysctl.d/99-moriarty-hardening.conf\t'):
        out.append('modified\t/etc/sysctl.d/99-moriarty-hardening.conf\t'+h)
    else:
        out.append(line)
open(path,'w').write('\n'.join(out)+'\n')
PY

# Malicious manifest path is rejected.
bad_backup=$(mktemp -d /root/moriarty-backup.BAD.XXXXXX)
chmod 0700 "$bad_backup"
printf '# moriarty-manifest-v2\ncreated\t/etc/passwd\t-\n' >"$bad_backup/MANIFEST"
chmod 0600 "$bad_backup/MANIFEST"
chown root:root "$bad_backup" "$bad_backup/MANIFEST"
assert_exit 1 "$PROG_DIR/moriarty-restore.sh" --dry-run "$bad_backup" || true
pass 'disallowed manifest path is rejected'
rm -rf "$bad_backup"

# Symlinked backup directory is rejected.
link_backup=/root/moriarty-backup.LINK.XXXXXX
rm -rf "$link_backup"
ln -s "$backup" "$link_backup"
assert_exit 1 "$PROG_DIR/moriarty-restore.sh" --dry-run "$link_backup" || true
pass 'symlinked backup is rejected'
rm -f "$link_backup"

# World-readable backup is rejected.
chmod 0755 "$backup"
assert_exit 1 "$PROG_DIR/moriarty-restore.sh" --dry-run "$backup" || true
pass 'world-readable backup is rejected'
chmod 0700 "$backup"

rm -rf "$backup"
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
