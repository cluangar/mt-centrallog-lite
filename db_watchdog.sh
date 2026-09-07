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
# (delegates to watchdog-cron.sh); `rearm` clears a tripped breaker. Any other
# first arg (or none) is the RUN_DIR, and the watchdog check/recovery runs.
case "${1:-}" in
  install|remove|uninstall|status)
    exec "$SELF_DIR/watchdog-cron.sh" "$@" ;;
esac

# ── rearm ────────────────────────────────────────────────────────────────────
# After MAX_FAILS consecutive failed recoveries the watchdog trips `.escalated`
# and stops acting until a human looks. `DB_WATCHDOG_AUTORECOVER=true` in .env
# does NOT override it — that is policy ("allowed to recover"); this is a circuit
# breaker ("stopped trying"). Both must be clear for recovery to run.
# ⚠ Resetting `.recover_fails` matters as much as deleting the flag: the counter
# sits AT MAX_FAILS when the breaker trips, so removing the file alone buys
# exactly ONE attempt before it re-trips.
if [ "${1:-}" = "rearm" ]; then
  _rr="${2:-${MTCL_RUN_DIR:-$SELF_DIR}}"
  _wd="$_rr/.watchdog"
  if [ ! -d "$_wd" ]; then
    echo "! no watchdog state at $_wd — nothing to re-arm (wrong run dir?)" >&2
    exit 1
  fi
  if [ -f "$_wd/.escalated" ]; then
    rm -f "$_wd/.escalated"
    echo "✓ breaker cleared (.escalated removed)"
  else
    echo "  breaker was not tripped (no .escalated)"
  fi
  echo 0 > "$_wd/.recover_fails"
  echo "✓ failure counter reset to 0"
  echo "  auto-recovery will run again on the next check (cron */10)."
  exit 0
fi

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

# The cooldown, failure counter and breaker all live in $WD — if that state can't
# be persisted we must REFUSE to run: an unthrottled recovery every 10 min with no
# way to escalate is exactly what the breaker exists to stop. (`mkdir -p` alone is
# not enough — an existing-but-unwritable dir passes it; test a write instead.)
mkdir -p "$SNAP" "$FOR" 2>/dev/null || { echo "watchdog[$PROJ]: cannot create state dir $WD — refusing to run (permissions?)" >&2; exit 1; }
: >> "$WD/.wtest" 2>/dev/null || { echo "watchdog[$PROJ]: state dir $WD is not writable — refusing to run" >&2; exit 1; }
rm -f "$WD/.wtest"
ts()   { date -u +%Y-%m-%dT%H:%M:%SZ; }
logl() { echo "$(ts) [$PROJ] $*" >> "$LOG"; }
say()  { [ -t 1 ] && echo "watchdog[$PROJ]: $*" || true; }   # only on interactive runs
dc()   { ( cd "$RUN" && docker compose "$@" ); }
cid()  { ( cd "$RUN" && docker compose ps -q "$1" 2>/dev/null ) | head -1; }

# Single-flight: never let two watchdogs interleave a stop/start cycle (a manual
# run racing a cron run, or a crond backlog after a reboot). The second would stop
# the backend the first just healed and burn a failure count on a recovery that
# already succeeded. The kernel releases the lock when the holder dies, so no
# stale lock can wedge future runs. If flock is missing, proceed as before.
if command -v flock >/dev/null 2>&1; then
  exec 9>"$WD/.lock"
  flock -n 9 || { logl "SKIP another watchdog run holds the lock — not acting"; say "another run is in progress — skipping"; exit 0; }
fi

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

# ── Telegram (optional, Phase 3, 2026-08-2x) ────────────────────────────────
# Reuses the SAME .env keys the backend/poller notifiers already read
# (TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID / TELEGRAM_CHAT_IDS), gated by
# TELEGRAM_ENABLED + TELEGRAM_DB_ALERTS — the same toggle the backend's own
# DB-health alerts check, so one switch silences both. Plain text: this is an
# out-of-app shell helper with no HTML/Markdown escaping story, and every
# value interpolated below is our OWN log text, never operator input.
# Never fails the run — curl errors are swallowed; this is a side-channel.
telegram_notify() {
  [ "$(env_get TELEGRAM_ENABLED)" = "false" ] && return 0
  [ "$(env_get TELEGRAM_DB_ALERTS)" = "false" ] && return 0
  # Live override: the Reports-page "DB-Health" checklist box, same
  # notification_settings table the backend/poller notifiers read. Query
  # read-only; an empty result (missing table/row — unmigrated or fresh DB,
  # or the DB itself is the thing that's broken right now) fails OPEN so a
  # config-loading hiccup never swallows the one alert this box most needs.
  local cat; cat=$(sqlite3 "file:$DB?mode=ro" "SELECT db_health_alerts FROM notification_settings WHERE id=1;" 2>/dev/null)
  [ "$cat" = "0" ] && return 0
  command -v curl >/dev/null 2>&1 || return 0
  local token; token=$(env_get TELEGRAM_BOT_TOKEN)
  [ -z "$token" ] && return 0
  local ids raw; raw=$(env_get TELEGRAM_CHAT_IDS)
  if [ -n "$raw" ]; then
    # "chatid:severity,chatid2:severity2" -> "chatid chatid2" (rsplit on the
    # LAST colon so a negative group id like -100123456:warning keeps its "-").
    ids=$(printf '%s' "$raw" | tr ',' '\n' | sed -E 's/:[^:]*$//' | tr '\n' ' ')
  else
    ids=$(env_get TELEGRAM_CHAT_ID)
  fi
  [ -z "$ids" ] && return 0
  local text; text="mt-centrallog DB watchdog [$PROJ]
$1"
  local id
  for id in $ids; do
    curl -s -m 10 -X POST "https://api.telegram.org/bot${token}/sendMessage" \
      -d "chat_id=${id}" --data-urlencode "text=${text}" >/dev/null 2>&1 || true
  done
}

ENABLED=$(env_get DB_WATCHDOG_ENABLED);         ENABLED=${ENABLED:-true}
AUTORECOVER=$(env_get DB_WATCHDOG_AUTORECOVER); AUTORECOVER=${AUTORECOVER:-true}
# Numeric tunables are validated: a typo'd .env value would make a `[ x -lt y ]`
# comparison fail OPEN (cooldown/escalation silently disabled) or make
# `docker logs --since` error into app_errs=0 (detection silently disabled).
# Digits only, else the default.
_num() { case "$1" in ''|*[!0-9]*) echo "$2";; *) echo "$1";; esac; }
APP_ERR_MIN=$(env_get DB_WATCHDOG_ERR_WINDOW_MIN);      APP_ERR_MIN=$(_num "$APP_ERR_MIN" 12)
APP_ERR_THRESHOLD=$(env_get DB_WATCHDOG_ERR_THRESHOLD); APP_ERR_THRESHOLD=$(_num "$APP_ERR_THRESHOLD" 3)
RECOVER_COOLDOWN=$(env_get DB_WATCHDOG_COOLDOWN_SEC);   RECOVER_COOLDOWN=$(_num "$RECOVER_COOLDOWN" 900)
MAX_FAILS=$(env_get DB_WATCHDOG_MAX_FAILS);             MAX_FAILS=$(_num "$MAX_FAILS" 3)
LOG_LINES=$(env_get DB_WATCHDOG_LOG_LINES);             LOG_LINES=$(_num "$LOG_LINES" 1000)

# Bounded log — this runs every 10 min forever via cron, so with no cap
# watchdog.log grows without limit. Trim to the newest LOG_LINES lines
# whenever it exceeds that count; a plain line-count trim (not date-based) so
# it behaves the same on a quiet box (few lines/day) and a noisy one (many
# recovery attempts) alike. Runs INSIDE the single-flight flock above, so no
# concurrent logl() writer can race the trim; `mv` is atomic on one filesystem.
if [ -f "$LOG" ]; then
  _loglines=$(wc -l < "$LOG" 2>/dev/null || echo 0)
  if [ "$_loglines" -gt "$LOG_LINES" ] 2>/dev/null; then
    tail -n "$LOG_LINES" "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
  fi
fi

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
# A MISSING file is its own state (the SD wiped it), not "malformed": the action
# is the same (autoheal promotes the newest valid backup) but the forensics must
# say so.
if [ "$res" = "ok" ]; then
  file_status="ok"
elif [ ! -f "$DB" ]; then
  file_status="missing"
else
  cp "$DB" "/tmp/wd_verify_$PROJ.db" 2>/dev/null
  file_status=$(sqlite3 "/tmp/wd_verify_$PROJ.db" "PRAGMA integrity_check;" 2>&1 | head -1)
  rm -f "/tmp/wd_verify_$PROJ.db"*
fi

confirmed=0
[ "$app_errs" -ge "$APP_ERR_THRESHOLD" ] && confirmed=1
case "$file_status" in ok) ;; *) confirmed=1 ;; esac

if [ "$confirmed" -eq 0 ]; then
  logl "WARN no action: res=[$res] file_status=ok app_errs=$app_errs (<${APP_ERR_THRESHOLD}) — not confirmed"
  say "no confirmed corruption — file verifies clean, app_errs=$app_errs (<${APP_ERR_THRESHOLD})"
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
  say "auto-recovery is OFF — forensics saved to $d; run 'sudo $SELF_DIR/recover_db.sh' to repair"
  telegram_notify "CORRUPTION detected (probe=[$res] file_status=[$file_status]). Auto-recovery is OFF — manual repair needed. Forensics: $d"
  exit 1
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
# ── count ONLY what the RESTARTED backend logged ─────────────────────────
# `docker start` appends to the container's existing log, so a fixed "--since 45s"
# window reaches back BEHIND the restart (this check runs ~30-35 s after it) and
# re-counts the dying backend's own malformed errors — the ones that triggered
# this recovery. That made a SUCCESSFUL recovery report as failed; three in a row
# escalated auto-recovery off on 2026-08-19 while `probe=[ok]` every time.
# Anchor to the new container's StartedAt instead (docker takes RFC3339 here).
SINCE=$(docker inspect -f '{{.State.StartedAt}}' "$BE" 2>/dev/null)
[ -z "$SINCE" ] && SINCE=45s
after=$(docker logs --since "$SINCE" "$BE" 2>&1 | grep -c "disk image is malformed")
res2=$(sqlite3 "file:$DB?mode=ro" "PRAGMA integrity_check;" 2>&1 | head -1)
if [ "$after" -eq 0 ] && { [ "$res2" = "ok" ] || docker logs --since "$SINCE" "$BE" 2>&1 | grep -q " 200 OK"; }; then
  logl "RECOVER ok: malformed(since-start)=0 probe=[$res2]"; echo 0 > "$FAILS"
  say "recovered OK — DB healthy again"
  telegram_notify "Auto-recovery SUCCEEDED — DB is healthy again (probe=[$res2])."
  exit 0
fi
n=$(( $(cat "$FAILS" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAILS"
logl "RECOVER FAILED (attempt $n/$MAX_FAILS): malformed(since-start)=$after probe=[$res2]"
say "recovery attempt $n/$MAX_FAILS did NOT clear it — see $LOG"
if [ "$n" -ge "$MAX_FAILS" ]; then
  touch "$ESC"
  logl "ESCALATE: $n consecutive failed recoveries — auto-recovery DISABLED. Manual: check $FOR, run '$SELF_DIR/recover_db.sh $RUN', then 'rm $ESC'."
  telegram_notify "ESCALATED — $n consecutive failed recoveries, auto-recovery DISABLED. Run recover_db.sh manually, then 'rm $ESC' to re-arm. Forensics: $d"
else
  telegram_notify "Recovery attempt $n/$MAX_FAILS FAILED (probe=[$res2]). Will retry after cooldown."
fi
exit 1
