#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Undo the changes recorded by moriarty.sh.
#
# Usage: sudo ./moriarty-restore.sh [backup-dir]
#        sudo ./moriarty-restore.sh --list
#
set -euo pipefail

PROG="${0##*/}"
DRY_RUN=0
BK=""

usage() {
  cat <<EOF
$PROG - restore the files changed by moriarty.sh

Usage: sudo ./$PROG [options] [backup-dir]

Arguments:
  backup-dir       Directory under /root, defaults to the most recent one

Options:
  -n, --dry-run    Print what would be restored
  -l, --list       List available backups and exit
  -h, --help       Show this help and exit
EOF
}

log() { printf '%s\n' "$*"; }
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  [dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -n|--dry-run) DRY_RUN=1 ;;
    -l|--list) ls -dt /root/opsec-backup.* 2>/dev/null || log "no backups found"; exit 0 ;;
    -*) log "unknown option: $1 (try --help)"; exit 2 ;;
    *) BK=$1 ;;
  esac
  shift
done

if [ -z "$BK" ]; then
  BK=""
  for cand in /root/opsec-backup.*; do
    [ -d "$cand" ] || continue
    case "$cand" in *.DRYRUN) continue ;; esac
    if [ -z "$BK" ] || [ "$cand" -nt "$BK" ]; then
      BK=$cand
    fi
  done
fi
if [ -z "$BK" ] || [ ! -d "$BK" ]; then
  log "no backup directory found under /root" >&2
  exit 1
fi
if [ ! -f "$BK/MANIFEST" ]; then
  log "$BK/MANIFEST is missing, refusing to guess" >&2
  exit 1
fi
if [ "$DRY_RUN" -eq 0 ] && [ "$EUID" -ne 0 ]; then
  log "run as root: sudo ./$PROG $BK" >&2
  exit 1
fi

log "Restoring from $BK"
while read -r action path; do
  [ -n "${path:-}" ] || continue
  case "$action" in
    modified)
      rel=${path#/}
      if [ ! -e "$BK/$rel" ] && [ ! -L "$BK/$rel" ]; then
        log "  missing backup for $path, skipped" >&2
        continue
      fi
      run mkdir -p "$(dirname "$path")"
      run cp -a "$BK/$rel" "$path"
      log "  restored $path"
      ;;
    created)
      run rm -f "$path"
      log "  removed  $path"
      ;;
    *)
      log "  unknown manifest entry: $action $path" >&2
      ;;
  esac
done < "$BK/MANIFEST"

run systemctl daemon-reload
run sysctl --system
if command -v nmcli >/dev/null 2>&1; then
  run nmcli general reload
fi
# try-restart leaves inactive units alone, so removing a config that
# belonged to a stopped service does not turn into an error.
for unit in NetworkManager systemd-resolved dnscrypt-proxy; do
  run systemctl try-restart "$unit"
done

log "Done. Reboot if the MAC policy changed."
