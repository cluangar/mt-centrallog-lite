#!/usr/bin/env bash
# mt-centrallog — manual deep DB recovery (run as root, stack writers stopped).
# Used when the watchdog escalates (auto-recovery couldn't clear a corruption).
# Materializes a fresh, defragmented DB via VACUUM INTO if the base file is clean;
# otherwise promotes the newest clean backup. Preserves the pre-recovery file.
#
#   sudo ./recover_db.sh [RUN_DIR]      # RUN_DIR defaults to this script's dir
#
# Do NOT run while the stack is up — stop the writers first:
#   ( cd RUN_DIR && docker compose stop poller backend )
set -e
# Needs root (rewrites root-owned sqlite_data). Auto-elevate so `./recover_db.sh` works.
[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN="${1:-$SELF_DIR}"
DATA="$RUN/sqlite_data"
DB="$DATA/centrallog.db"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
[ -f "$DB" ] || { echo "no DB at $DB"; exit 1; }
cd "$DATA"

echo "== preserve current file =="
cp -a "$DB" "$DB.pre-recovery-$TS"; echo "  saved $DB.pre-recovery-$TS"

echo "== base file integrity (writers must be stopped) =="
base=$(sqlite3 "$DB" "PRAGMA integrity_check;" 2>&1 | head -1); echo "  integrity=$base"

pick=""
if [ "$base" = "ok" ]; then
  echo "== base clean → VACUUM INTO fresh copy =="
  rm -f /tmp/recover_fresh.db
  sqlite3 "$DB" "VACUUM INTO '/tmp/recover_fresh.db'"
  fi_=$(sqlite3 /tmp/recover_fresh.db "PRAGMA integrity_check;" 2>&1 | head -1)
  if [ "$fi_" = "ok" ]; then pick=/tmp/recover_fresh.db; echo "  fresh copy ok"; else echo "  VACUUM copy not ok ($fi_)"; rm -f /tmp/recover_fresh.db; fi
fi

if [ -z "$pick" ]; then
  echo "== base not usable → search newest CLEAN backup =="
  for cand in "$DB.bak" "$RUN"/.watchdog/snapshots/centrallog.*.db "$DATA"/backups/centrallog_backup_*.db; do
    [ -f "$cand" ] || continue
    cp "$cand" /tmp/recover_cand.db 2>/dev/null || continue
    c=$(sqlite3 /tmp/recover_cand.db "PRAGMA integrity_check;" 2>&1 | head -1)
    if [ "$c" = "ok" ]; then pick=/tmp/recover_cand.db; echo "  using clean backup: $cand"; break; fi
    rm -f /tmp/recover_cand.db
  done
fi

[ -n "$pick" ] || { echo "!! no clean source found — ABORTING, live file untouched"; exit 1; }

echo "== swap in (root-owned, no sidecars) =="
rm -f "$DB-wal" "$DB-shm"
cp -a "$pick" "$DB"
chown root:root "$DB" 2>/dev/null || true
chmod 644 "$DB"
rm -f /tmp/recover_fresh.db /tmp/recover_cand.db
echo "== done — final integrity =="
sqlite3 "file:$DB?mode=ro" "PRAGMA integrity_check;" 2>/dev/null | head -1 || sqlite3 "$DB" "PRAGMA integrity_check;" | head -1
echo "Now start the stack:  ( cd $RUN && docker compose start backend poller )"
echo "If the watchdog had escalated:  rm $RUN/.watchdog/.escalated"
