#!/usr/bin/env bash
# mt-centrallog — manual deep DB recovery (run as root, stack writers stopped).
# Used when the watchdog escalates (auto-recovery couldn't clear a corruption).
# Materializes a fresh, defragmented DB via VACUUM INTO if the base file is clean; otherwise promotes the
# NEWEST usable backup — every candidate is gated (size floor + non-empty schema + ≥1 row in `users` +
# integrity_check) and every rejection is written to stdout and <run-dir>/.watchdog/recover.log.
# Preserves the pre-recovery file.
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
# ⚠ Preflight — same rule as db_watchdog.sh (measured on KBR 2026-10-12: no sqlite3 CLI on that box).
# With `set -e` a missing sqlite3 would abort at the first `base=$(sqlite3 …)` with no message at all,
# which reads as "the script crashed" rather than "this box cannot run a recovery". Fail loudly instead.
command -v sqlite3 >/dev/null 2>&1 || { echo "sqlite3 is not installed — recover_db.sh cannot gate or verify any candidate. Install sqlite3 first." >&2; exit 1; }

# ── C3 (#39, 2026-10-11): candidate selection is GATED, ordered, and RECORDED ──────────────
# Three defects this closes: (1) the old loop accepted the FIRST candidate whose
# `PRAGMA integrity_check` said `ok` — and a 0-byte file answers `ok`, so an empty snapshot could be
# promoted over a good 752 MB backup; (2) the snapshot glob expanded timestamp-ASCENDING (oldest
# first) while its own comment promised "newest CLEAN backup"; (3) the third source was
# `$DATA/backups/` = <run-dir>/sqlite_data/backups/, a directory NO compose creates — both composes
# bind `./backup_data:/data/backups` (manager.py:24 BACKUP_DIR), so the deep-repair path silently
# had two candidates instead of three exactly when it is called for. The legacy path is kept for
# pre-mount layouts; the real one is searched first.
# Every acceptance verdict and every rejection reason now goes to stdout AND
# <run-dir>/.watchdog/recover.log, so a recovery is explainable after the fact.
WD="$RUN/.watchdog"
RLOG="$WD/recover.log"
mkdir -p "$WD" 2>/dev/null || RLOG=""          # a log we cannot write must never fail the recovery
rlog() { echo "$@"; if [ -n "$RLOG" ]; then printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$RLOG" 2>/dev/null || true; fi; }
env_get() {   # same reader db_watchdog.sh uses, so one .env key serves both scripts
  sed -n -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$RUN/.env" 2>/dev/null \
    | tail -1 | sed -E 's/[[:space:]]*#.*$//; s/^"//; s/"$//' | tr -d '[:space:]'
}
_num() { case "$1" in ''|*[!0-9]*) echo "$2";; *) echo "$1";; esac; }
MIN_BYTES=$(_num "$(env_get DB_WATCHDOG_SNAPSHOT_MIN_BYTES)" 10000000)   # same floor as C1

# gate_candidate <file> — prints the verdict; returns 0 only when the file may become the live DB.
# Integrity alone is NOT a test (an empty file passes it), so size + schema + the app's own
# non-empty-table requirement (DB_AUTOHEAL_MIN_ROWS_TABLE=users) all have to hold.
gate_candidate() {
  _sz=$(stat -c%s "$1" 2>/dev/null || echo 0)
  if [ "$_sz" -lt "$MIN_BYTES" ] 2>/dev/null; then echo "too small: ${_sz} B < ${MIN_BYTES} B floor"; return 1; fi
  _t=$(sqlite3 "$1" "SELECT count(*) FROM sqlite_master;" 2>&1 | head -1)
  case "$_t" in ''|*[!0-9]*) echo "unreadable: ${_t}"; return 1;; esac
  if [ "$_t" -le 0 ] 2>/dev/null; then echo "no tables (sqlite_master is empty)"; return 1; fi
  _u=$(sqlite3 "$1" "SELECT count(*) FROM users;" 2>&1 | head -1)
  case "$_u" in ''|*[!0-9]*) echo "no users table (${_u}) — the app's own auto-heal requires ≥ 1 row"; return 1;; esac
  if [ "$_u" -lt 1 ] 2>/dev/null; then echo "users table is empty"; return 1; fi
  _c=$(sqlite3 "$1" "PRAGMA integrity_check;" 2>&1 | head -1)
  if [ "$_c" != "ok" ]; then echo "integrity_check: ${_c}"; return 1; fi
  echo "${_sz} B, ${_t} tables, ${_u} users rows, integrity ok"; return 0
}

rlog "== preserve current file =="
cp -a "$DB" "$DB.pre-recovery-$TS"; rlog "  saved $DB.pre-recovery-$TS"

rlog "== base file integrity (writers must be stopped) =="
base=$(sqlite3 "$DB" "PRAGMA integrity_check;" 2>&1 | head -1); rlog "  integrity=$base"

pick=""
if [ "$base" = "ok" ]; then
  rlog "== base clean → VACUUM INTO fresh copy =="
  rm -f /tmp/recover_fresh.db
  sqlite3 "$DB" "VACUUM INTO '/tmp/recover_fresh.db'"
  if v=$(gate_candidate /tmp/recover_fresh.db); then
    pick=/tmp/recover_fresh.db; rlog "  fresh copy $v"
  else
    rlog "  fresh copy REJECTED: $v"; rm -f /tmp/recover_fresh.db
  fi
fi

if [ -z "$pick" ]; then
  rlog "== base not usable → search EVERY backup source, newest first, each one gated =="
  cands=$(
    for f in "$DB.bak" \
             "$RUN"/backup_data/centrallog_backup_*.db \
             "$DATA"/backups/centrallog_backup_*.db \
             "$RUN"/.watchdog/snapshots/centrallog.*.db; do
      if [ -f "$f" ]; then stat -c '%Y %n' "$f"; fi
    done | sort -rn | cut -d' ' -f2-
  )
  rlog "  floor: size ≥ ${MIN_BYTES} B, sqlite_master non-empty, users ≥ 1 row, integrity_check ok"
  tried=0
  while IFS= read -r cand; do
    if [ -z "$cand" ]; then continue; fi
    tried=$((tried + 1))
    rm -f /tmp/recover_cand.db
    if ! cp "$cand" /tmp/recover_cand.db 2>/dev/null; then
      rlog "  reject  $cand — could not read it"; continue
    fi
    if v=$(gate_candidate /tmp/recover_cand.db); then
      pick=/tmp/recover_cand.db; rlog "  USING   $cand ($v)"; break
    fi
    rlog "  reject  $cand — $v"; rm -f /tmp/recover_cand.db
  done <<< "$cands"
  if [ "$tried" -eq 0 ]; then
    rlog "  no candidate files found in: $DB.bak · $RUN/backup_data/ · $DATA/backups/ · $RUN/.watchdog/snapshots/"
  fi
fi

if [ -z "$pick" ]; then rlog "!! no usable source found — ABORTING, live file untouched"; exit 1; fi

rlog "== swap in (root-owned, no sidecars) — source: $pick =="
rm -f "$DB-wal" "$DB-shm"
cp -a "$pick" "$DB"
chown root:root "$DB" 2>/dev/null || true
chmod 644 "$DB"
rm -f /tmp/recover_fresh.db /tmp/recover_cand.db
fin=$(sqlite3 "file:$DB?mode=ro" "PRAGMA integrity_check;" 2>/dev/null | head -1)
if [ -z "$fin" ]; then fin=$(sqlite3 "$DB" "PRAGMA integrity_check;" 2>&1 | head -1); fi
rlog "== done — final integrity: $fin (pre-recovery copy kept at $DB.pre-recovery-$TS) =="
echo "Now start the stack:  ( cd $RUN && docker compose start backend poller )"
echo "If the watchdog had escalated:  rm $RUN/.watchdog/.escalated"
