#!/usr/bin/env bash
# mt-centrallog — DB watchdog + auto-recovery.
# Ships with the Lite stack; installed into the run/install dir and driven by cron
# (every 10 min) via watchdog-cron.sh. Runs as the invoking user (must be in the
# `docker` group); no sudo, no container — it only opens the live DB READ-ONLY.
#
# SCOPED TO ONE DEPLOYMENT by its compose run-dir, so several versions can run on
# one box (each with its own cron line + state). Container names are resolved
# dynamically from the run-dir's compose project — never hardcoded.
#   run-dir precedence:  $1 arg  >  $MTCL_RUN_DIR env  >  the dir this script sits in
#
# Detects live DB corruption via TWO signals — a read-only integrity_check on the
# file AND the backend's own `database disk image is malformed` log count (the live
# path can be corrupt while the on-disk file still verifies clean) — and, when
# DB_WATCHDOG_AUTORECOVER=true, recovers with: stop both writers, start the backend
# alone so its boot-time auto-heal + WAL recovery run writer-free, then start the
# poller. Flags come from the run-dir .env (see .env.example: DB_WATCHDOG_*).
set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

# Single entry point: `db_watchdog.sh install|remove|status` manages the cron
# (delegates to watchdog-cron.sh). Any other first arg (or none) is the RUN_DIR,
# and the watchdog check/recovery runs.
case "${1:-}" in
  install|remove|uninstall|status)
    exec "$SELF_DIR/watchdog-cron.sh" "$@" ;;
esac

# Runs as the operator (the user whose crontab holds it — NOT root). It needs only
# docker-group access, read of the world-readable DB, and write of its own state
# dir, so no sudo is required — run it as yourself. Only recover_db.sh needs root.
RUN="${1:-${MTCL_RUN_DIR:-$SELF_DIR}}"
PROJ="$(basename "$RUN")"
DATA="$RUN/sqlite_data"
DB="$DATA/centrallog.db"
WD="$RUN/.watchdog"                      # per-deployment state (self-contained)
SNAP="$WD/snapshots"; FOR="$WD/forensics"; LOG="$WD/watchdog.log"
COOL="$WD/.last_recover"; FAILS="$WD/.recover_fails"; ESC="$WD/.escalated"
HEALTH_WAIT=90

mkdir -p "$SNAP" "$FOR"
ts()   { date -u +%Y-%m-%dT%H:%M:%SZ; }
logl() { echo "$(ts) [$PROJ] $*" >> "$LOG"; }
say()  { [ -t 1 ] && echo "watchdog[$PROJ]: $*" || true; }   # only on interactive runs
dc()   { ( cd "$RUN" && docker compose "$@" ); }
cid()  { ( cd "$RUN" && docker compose ps -q "$1" 2>/dev/null ) | head -1; }

if [ ! -f "$RUN/docker-compose.yml" ] && [ ! -f "$RUN/docker-compose.yaml" ]; then
  logl "ERROR no compose file in RUN=$RUN — wrong run-dir?"
  say "no docker-compose.yml in '$RUN'. Run from the deployment dir, or: db_watchdog.sh <run-dir>"
  exit 1
fi

# Read a value from the run-dir .env (strips inline comments, quotes, whitespace).
env_get() {
  sed -n -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$RUN/.env" 2>/dev/null \
    | tail -1 | sed -E 's/[[:space:]]*#.*$//; s/^"//; s/"$//' | tr -d '[:space:]'
}

ENABLED=$(env_get DB_WATCHDOG_ENABLED);         ENABLED=${ENABLED:-true}
AUTORECOVER=$(env_get DB_WATCHDOG_AUTORECOVER); AUTORECOVER=${AUTORECOVER:-true}
APP_ERR_MIN=$(env_get DB_WATCHDOG_ERR_WINDOW_MIN);      APP_ERR_MIN=${APP_ERR_MIN:-12}
APP_ERR_THRESHOLD=$(env_get DB_WATCHDOG_ERR_THRESHOLD); APP_ERR_THRESHOLD=${APP_ERR_THRESHOLD:-3}
RECOVER_COOLDOWN=$(env_get DB_WATCHDOG_COOLDOWN_SEC);   RECOVER_COOLDOWN=${RECOVER_COOLDOWN:-900}
MAX_FAILS=$(env_get DB_WATCHDOG_MAX_FAILS);             MAX_FAILS=${MAX_FAILS:-3}

[ "$ENABLED" = "true" ] || { say "disabled (DB_WATCHDOG_ENABLED=false) — set it true in .env to enable"; exit 0; }

# This is a DISK-corruption feature. In ramdisk mode the live DB is in RAM (tmpfs)
# and <run-dir>/sqlite_data/centrallog.db is only a periodic sync copy — not the
# live DB — so the checks/recovery below don't apply. (Lite always has this false.)
if [ "$(env_get RAMDISK_ENABLED)" = "true" ]; then
  logl "SKIP RAMDISK_ENABLED=true — live DB is in RAM; disk watchdog not applicable"
  say "skipped — RAMDISK_ENABLED=true (live DB is in RAM, not on disk)"; exit 0
fi

BE=$(cid backend); PO=$(cid poller)
# No backend container = the stack is down (or not deployed). The run dir was already
# validated to have a compose file above, so this is not an error — just skip. A
# deliberate `start.sh down` must neither spam errors nor be resurrected here.
if [ -z "$BE" ]; then
  logl "skip: stack not running (no backend container)"
  say "stack is not running — nothing to do (will not resurrect a deliberate 'down')"; exit 0
fi

# ── signals ──────────────────────────────────────────────────────────────
res=$(sqlite3 "file:$DB?mode=ro" "PRAGMA integrity_check;" 2>&1 | head -1)
app_errs=$(docker logs --since "${APP_ERR_MIN}m" "$BE" 2>&1 | grep -c "disk image is malformed")

# ── healthy fast-path: file reads ok AND backend not erroring → snapshot ──
if [ "$res" = "ok" ] && [ "$app_errs" -eq 0 ]; then
  newest=$(ls -t "$SNAP"/centrallog.*.db 2>/dev/null | head -1)
  if [ -z "$newest" ] || [ $(( $(date +%s) - $(stat -c%Y "$newest") )) -ge 3300 ]; then
    dst="$SNAP/centrallog.$(date -u +%Y%m%dT%H%M%SZ).db"
    if sqlite3 "file:$DB?mode=ro" ".backup '$dst'" 2>>"$LOG"; then
      sqlite3 "$dst" "PRAGMA journal_mode=DELETE;" >/dev/null 2>>"$LOG"; rm -f "$dst-wal" "$dst-shm"
      if [ "$(sqlite3 "file:$dst?mode=ro" 'PRAGMA integrity_check;' 2>&1 | head -1)" = "ok" ]; then
        logl "OK integrity=ok app_errs=0 snapshot=$(basename "$dst")"
        ls -t "$SNAP"/centrallog.*.db 2>/dev/null | tail -n +25 | xargs -r rm -f
      else
        logl "WARN snapshot failed own integrity check, removed"; rm -f "$dst" "$dst-wal" "$dst-shm"
      fi
    else
      logl "WARN .backup command failed"
    fi
  fi
  say "healthy — integrity ok, app_errs=0"
  exit 0
fi

# ── classify: real malformed vs a benign probe error (WAL DB w/ no -shm) ──
if [ "$res" = "ok" ]; then
  file_status="ok"
else
  cp "$DB" "/tmp/wd_verify_$PROJ.db" 2>/dev/null
  file_status=$(sqlite3 "/tmp/wd_verify_$PROJ.db" "PRAGMA integrity_check;" 2>&1 | head -1)
  rm -f "/tmp/wd_verify_$PROJ.db"*
fi

confirmed=0
[ "$app_errs" -ge "$APP_ERR_THRESHOLD" ] && confirmed=1
case "$file_status" in ok) ;; *) confirmed=1 ;; esac

if [ "$confirmed" -eq 0 ]; then
  logl "WARN probe non-ok res=[$res] but file_status=ok app_errs=$app_errs (<${APP_ERR_THRESHOLD}) — no action"
  say "probe returned '$res' but the DB file verifies clean — no action needed"
  exit 0
fi

# ── confirmed corruption ─────────────────────────────────────────────────
logl "CONFIRMED corruption: probe=[$res] file_status=[$file_status] app_errs=$app_errs"
say "CORRUPTION confirmed (file=$file_status, backend malformed errors=$app_errs)"
stamp=$(date -u +%Y%m%dT%H%M%SZ); d="$FOR/$stamp"; mkdir -p "$d"
{ echo "=== $(ts) $PROJ ==="; echo "probe=[$res] file_status=[$file_status] app_errs=$app_errs"
  echo "--- ls ---"; ls -la --time-style=+%H:%M:%S "$DATA"; } > "$d/state.txt" 2>&1
docker logs --tail 400 "$BE" > "$d/backend.log" 2>&1
[ -n "$PO" ] && docker logs --tail 400 "$PO" > "$d/poller.log" 2>&1

if [ "$AUTORECOVER" != "true" ]; then
  logl "AUTORECOVER=off — detected + forensics saved to $d; NOT restarting"
  say "auto-recovery is OFF — forensics saved to $d; run 'sudo $SELF_DIR/recover_db.sh' to repair"; exit 1
fi
if [ -f "$ESC" ]; then
  logl "ESCALATED flag present ($ESC) — auto-recovery disabled; needs manual attention. rm the file to re-arm."
  say "escalated after repeated failures — run 'sudo $SELF_DIR/recover_db.sh', then 'rm $ESC'"; exit 1
fi
now=$(date +%s); last=$(cat "$COOL" 2>/dev/null || echo 0)
if [ $(( now - last )) -lt "$RECOVER_COOLDOWN" ]; then
  logl "RECOVER suppressed (cooldown, last $(date -u -d @"$last" +%H:%M:%SZ))"
  say "recovery suppressed (cooldown, last attempt $(date -u -d @"$last" +%H:%M:%SZ))"; exit 1
fi
echo "$now" > "$COOL"

# ── recovery: stop both writers, heal backend alone, then start poller ───
say "recovering: stop writers → heal backend → start poller ..."
logl "RECOVER: stop poller+backend"
dc stop poller backend >> "$LOG" 2>&1
logl "RECOVER: start backend (boot-time auto-heal + WAL recovery run writer-free)"
dc start backend >> "$LOG" 2>&1
BE=$(cid backend); waited=0
while [ "$waited" -lt "$HEALTH_WAIT" ]; do
  h=$(docker inspect -f '{{.State.Health.Status}}' "$BE" 2>/dev/null || echo unknown)
  [ "$h" = "healthy" ] && break
  sleep 5; waited=$(( waited + 5 ))
done
logl "RECOVER: backend health=$h after ${waited}s; start poller"
dc start poller >> "$LOG" 2>&1
sleep 20

# ── verify it cleared ────────────────────────────────────────────────────
BE=$(cid backend)
after=$(docker logs --since 45s "$BE" 2>&1 | grep -c "disk image is malformed")
res2=$(sqlite3 "file:$DB?mode=ro" "PRAGMA integrity_check;" 2>&1 | head -1)
if [ "$after" -eq 0 ] && { [ "$res2" = "ok" ] || docker logs --since 45s "$BE" 2>&1 | grep -q " 200 OK"; }; then
  logl "RECOVER ok: malformed(45s)=0 probe=[$res2]"; echo 0 > "$FAILS"
  say "recovered OK — DB healthy again"; exit 0
fi
n=$(( $(cat "$FAILS" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAILS"
logl "RECOVER FAILED (attempt $n/$MAX_FAILS): malformed(45s)=$after probe=[$res2]"
say "recovery attempt $n/$MAX_FAILS did NOT clear it — see $LOG"
if [ "$n" -ge "$MAX_FAILS" ]; then
  touch "$ESC"
  logl "ESCALATE: $n consecutive failed recoveries — auto-recovery DISABLED. Manual: check $FOR, run '$SELF_DIR/recover_db.sh $RUN', then 'rm $ESC'."
fi
exit 1
