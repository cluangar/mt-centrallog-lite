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
# PATH is pinned so a cron run behaves exactly like an interactive one. `DB_WATCHDOG_EXTRA_PATH` is a
# TEST-ONLY hook (the PATH-shim harness in backend/tests/test_watchdog_scripts.py prepends fake
# sqlite3/docker to it); nothing in production sets it and cron never sees it.
export PATH="${DB_WATCHDOG_EXTRA_PATH:+$DB_WATCHDOG_EXTRA_PATH:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

# Single entry point: `db_watchdog.sh install|remove|status` manages the cron
# (delegates to watchdog-cron.sh); `rearm` clears a tripped breaker; `events`
# prints the newest rows of the durable event record (events.tsv, written by every
# run). Any other first arg (or none) is the RUN_DIR, and the check/recovery runs.
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

# ── events [<run-dir>] [N] ───────────────────────────────────────────────────
# The operator-facing half of the event record: the newest N rows (default 20) as
# an aligned table. Read-only — needs no docker group, no compose file, no DB.
# For trends/flags use `python3 tools/watchdog_report.py <run-dir>/.watchdog/events.tsv`.
if [ "${1:-}" = "events" ]; then
  _er="${2:-${MTCL_RUN_DIR:-$SELF_DIR}}"; _en="${3:-20}"
  case "$_en" in ''|*[!0-9]*) _en=20;; esac
  _ef="$_er/.watchdog/events.tsv"
  _hb="$_er/.watchdog/heartbeat"
  if [ ! -s "$_ef" ]; then
    echo "watchdog[$(basename "$_er")]: no flagged runs in $_ef — at DB_WATCHDOG_EVENTS_LEVEL=critical (the default) a row is written only when something needs attention."
    if [ -f "$_hb" ]; then
      echo "  last watchdog run: $(stat -c %y "$_hb" 2>/dev/null)  (read from .watchdog/heartbeat — an empty record means nothing was flagged, NOT that the cron stopped)"
    else
      echo "  no .watchdog/heartbeat either — the watchdog has not run from this run dir (cron not installed? wrong run dir? box off?)"
    fi
    echo "  set DB_WATCHDOG_EVENTS_LEVEL=all in .env for one row per run; the per-run detail is in $_er/.watchdog/watchdog.log"
    exit 0
  fi
  echo "watchdog events — $_er  (newest $_en of $(wc -l < "$_ef"))"
  [ -f "$_hb" ] && echo "  last watchdog run (heartbeat): $(stat -c %y "$_hb" 2>/dev/null)"
  printf '%-21s %-24s %-26s %8s %7s %8s %5s  %s\n' TS PROBE ACTION APP_ERRS SNAP# SNAP_MB ZERO SNAP_STATE
  tail -n "$_en" "$_ef" | awk -F'\t' '{printf "%-21s %-24s %-26s %8s %7s %8.1f %5s  %s\n", $1, substr($6,1,24), $9, $8, $12, $13/1048576, $14, $10}'
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

# ── durable event record — one row per run, on EVERY exit path ──────────────
# watchdog.log is a human log trimmed to LOG_LINES: on a */10 cron that is about
# seven days, and it cannot answer "what has the snapshot job been doing this
# month". The 2026-10-11 diagnosis of BACKLOG #37/#38/#39 had to be done by hand,
# from file mtimes and directory listings, because no record survived. events.tsv
# is the machine-readable answer: a fixed-column TSV, appended once per run by an
# EXIT trap (so a skip, a refusal or an unexpected failure is still a row), trimmed
# to its own cap (DB_WATCHDOG_EVENTS_LINES) so the watchdog.log trim never eats it.
# It is a FILE and not a DB table on purpose: the watchdog must keep recording when
# the database is the thing that is broken.
# columns (17, tab-separated): ts  project  run_dir  backend_container  db_bytes
#   probe_res  file_status  app_errs  action  snapshot  snapshot_bytes
#   snaps_count  snaps_bytes  zero_count  recover_fails  escalated  dur_s
# action: healthy | app_contention | app_down | app_restarted | app_restart_failed |
#   app_down_cooldown | not_confirmed | confirmed | confirmed_no_autorecover |
#   confirmed_escalated_breaker | confirmed_cooldown | recovered | recover_failed |
#   escalated | skip_locked | skip_stack | skip_ramdisk | disabled |
#   error_no_compose | error_no_sqlite3 | interrupted | aborted
# snapshot: ok | backup_failed | own_check_failed | too_small | skipped_gate | not_attempted
EVENTS="$WD/events.tsv"; EVENTS_LINES=5000; T0=$(date +%s); HAVE_LOCK=0
ACTION=""; SNAPSTAT="not_attempted"; SNAPBYTES=0
snaps_count=0; snaps_bytes=0; zero_count=0
_snapstat() {   # stat-only inventory of the snapshot dir (never reads file content)
  snaps_count=$(find "$SNAP" -maxdepth 1 -name 'centrallog.*.db' 2>/dev/null | wc -l)
  zero_count=$(find "$SNAP" -maxdepth 1 -name 'centrallog.*.db' -size 0 2>/dev/null | wc -l)
  snaps_bytes=$(find "$SNAP" -maxdepth 1 -name 'centrallog.*.db' -printf '%s\n' 2>/dev/null \
                | awk '{s+=$1} END{print s+0}')
}
_is_critical() {   # does this run deserve a row when DB_WATCHDOG_EVENTS_LEVEL=critical?
  case "${ACTION:-aborted}" in
    healthy|skip_stack|skip_ramdisk|disabled) ;;   # routine no-ops — the heartbeat covers them
    *) return 0 ;;
  esac
  case "$SNAPSTAT" in backup_failed|own_check_failed|too_small) return 0 ;; esac   # the snapshot job IS the failure
  # NO `zero_count > 0` trigger here, deliberately: on a box that still holds old 0-byte snapshots
  # that condition is true on EVERY run, so the "critical only" level would record all 144 runs/day —
  # the exact cost this level exists to avoid. The moment that matters is already recorded (the
  # failed attempt that left the empty file), and the analyzer reads zero_count from whatever rows
  # do exist. C1 (2026-10-11) removes empty/partial snapshots on every failure branch and rejects
  # them before accepting one, so zero_count is now a historical field, not a trigger.
  [ "${app_errs:-0}" -gt 0 ] 2>/dev/null && return 0
  [ -n "${res:-}" ] && [ "$res" != "ok" ] && return 0
  return 1
}
logevent() {   # write the run's row; never fails the run it records
  _snapstat
  touch "$WD/heartbeat" 2>/dev/null || true   # mtime = "cron last ran"; costs no log growth ($WD is the state dir)
  # critical (default) records only runs that carry signal; `all` records every run. The
  # routine healthy/skip rows are the bulk of the file, and the heartbeat + watchdog.log still
  # prove a healthy box is alive — so a small flash disk is not charged 144 rows/day.
  if [ "${EVENTS_LEVEL:-critical}" = "critical" ] && ! _is_critical; then
    # One exception: a gate skip whose LAST recorded snapshot attempt failed IS the #37
    # suppression window in progress — keep that row so the analyzer can name it.
    if [ "$SNAPSTAT" = "skipped_gate" ] && [ -f "$EVENTS" ] && \
       tail -n 1 "$EVENTS" 2>/dev/null | cut -f10 | grep -qE '^(backup_failed|own_check_failed|too_small)$'; then
      :
    else
      return 0
    fi
  fi
  local _probe=$(printf '%s' "${res:-}" | tr -d '\t\n' | cut -c1-120)
  local _be=$(printf '%s' "${BE:-}" | tr -d '\t\n[:space:]' | cut -c1-24)
  local _dbb=$(stat -c%s "$DB" 2>/dev/null || echo 0)
  local _fs=$(printf '%s' "${file_status:-}" | tr -d '\t\n' | cut -c1-120)
  # project/run_dir are capped and tab-stripped too: an uncapped path — or one containing a
  # tab — would break the fixed 17-column layout every reader depends on.
  local _proj=$(printf '%s' "${PROJ:-}" | tr -d '\t\n' | cut -c1-24)
  local _run=$(printf '%s' "${RUN:-}" | tr -d '\t\n' | cut -c1-128)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(ts)" "$_proj" "$_run" "$_be" "$_dbb" "$_probe" "$_fs" "${app_errs:-0}" \
    "${ACTION:-aborted}" "$SNAPSTAT" "$SNAPBYTES" "$snaps_count" "$snaps_bytes" "$zero_count" \
    "$(cat "$FAILS" 2>/dev/null || echo 0)" "$([ -f "$ESC" ] && echo 1 || echo 0)" \
    "$(( $(date +%s) - T0 ))" >> "$EVENTS" 2>/dev/null || true
  # Retention is applied AFTER the append, so the cap is the true steady-state size of the
  # record (this run's row included). Only the LOCK OWNER may rewrite the shared file: a run
  # that lost the flock (ACTION=skip_locked) would race the holder's append with its
  # `tail | mv` and could drop the holder's row. `mv` is atomic on one filesystem.
  # The trim fires only when the file is over the cap BY A SLACK of 200 rows: on flash (the
  # Lite SD) the REWRITE is the cost, not the size — this turns ~144 rewrites/day into ~1/day.
  local _evn=$(wc -l < "$EVENTS" 2>/dev/null || echo 0)
  if [ "$HAVE_LOCK" = "1" ] && [ "$_evn" -gt $((EVENTS_LINES + 200)) ] 2>/dev/null; then
    tail -n "$EVENTS_LINES" "$EVENTS" > "$EVENTS.tmp" 2>/dev/null && mv "$EVENTS.tmp" "$EVENTS"
  fi
}
trap 'logevent' EXIT
trap 'ACTION="interrupted"; exit 130' INT TERM

# Single-flight: never let two watchdogs interleave a stop/start cycle (a manual
# run racing a cron run, or a crond backlog after a reboot). The second would stop
# the backend the first just healed and burn a failure count on a recovery that
# already succeeded. The kernel releases the lock when the holder dies, so no
# stale lock can wedge future runs. If flock is missing, proceed as before.
if command -v flock >/dev/null 2>&1; then
  exec 9>"$WD/.lock"
  flock -n 9 || { ACTION="skip_locked"; logl "SKIP another watchdog run holds the lock — not acting (no state rewrite by this run)"; say "another run is in progress — skipping"; exit 0; }
  HAVE_LOCK=1        # this run owns the lock; only it may rewrite shared state files
else
  HAVE_LOCK=1        # no flock available — single-instance assumption, unchanged from before
fi

if [ ! -f "$RUN/docker-compose.yml" ] && [ ! -f "$RUN/docker-compose.yaml" ]; then
  logl "ERROR no compose file in RUN=$RUN — wrong run-dir?"
  ACTION="error_no_compose"
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
  local cat=""; command -v sqlite3 >/dev/null 2>&1 && cat=$(sqlite3 "file:$DB?mode=ro" "SELECT db_health_alerts FROM notification_settings WHERE id=1;" 2>/dev/null)
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
# App-level contention alarm (#76). The file can read perfectly clean while the backend is losing the
# SQLite write lock on every request — the shape an operator sees as "the database is dead" while every
# corruption signal says healthy. Detection ONLY: stopping the writers does not release a lock, so this
# NEVER triggers recovery. 0 = never alert; while the streak continues, at most one alert per repeat
# window (the same storm rule C4 learned on the probe alert).
LOCK_ALERT=$(env_get DB_WATCHDOG_LOCK_ALERT); LOCK_ALERT=$(_num "$LOCK_ALERT" 5)
LOCK_ALERT_REPEAT=$(_num "$(env_get DB_WATCHDOG_LOCK_ALERT_REPEAT_SEC)" 3600)
RECOVER_COOLDOWN=$(env_get DB_WATCHDOG_COOLDOWN_SEC);   RECOVER_COOLDOWN=$(_num "$RECOVER_COOLDOWN" 900)
MAX_FAILS=$(env_get DB_WATCHDOG_MAX_FAILS);             MAX_FAILS=$(_num "$MAX_FAILS" 3)
LOG_LINES=$(env_get DB_WATCHDOG_LOG_LINES);             LOG_LINES=$(_num "$LOG_LINES" 1000)
EVENTS_LINES=$(env_get DB_WATCHDOG_EVENTS_LINES);      EVENTS_LINES=$(_num "$EVENTS_LINES" 5000)
# Acceptance floor for a watchdog snapshot (#38): a 0-byte file passes `PRAGMA integrity_check`,
# so size alone must gate it. Digits only; a typo falls back to the default. Set it to 1 to
# effectively disable the floor on a box whose DB is legitimately tiny.
SNAP_MIN_BYTES=$(env_get DB_WATCHDOG_SNAPSHOT_MIN_BYTES); SNAP_MIN_BYTES=$(_num "$SNAP_MIN_BYTES" 10000000)
# How many newest snapshots to keep. It WAS hardcoded to 24 — on a box with a 2.6 GB
# database that is 62 GB of copies, and every accepted snapshot is DB-sized. Floored at
# 1: a watchdog with no snapshot is not a safety net.
SNAP_KEEP=$(env_get DB_WATCHDOG_SNAP_KEEP); SNAP_KEEP=$(_num "$SNAP_KEEP" 24)
if [ "$SNAP_KEEP" -lt 1 ] 2>/dev/null; then SNAP_KEEP=1; fi
# ── app liveness: the case where every FILE check says healthy and the app is dead ──
# Docker already probes the backend's own /api/v1/health every 10 s and marks the container `unhealthy`
# when it stops answering; a `compose down` followed by an interrupted `up` can also leave a service in
# `created` (measured on KBR 2026-11-01, the outage where the SPA served and every /api 502'd). Neither
# is a corruption signal, so until now NOTHING in this file reacted to either. Detection is always on;
# the restart is opt-in (`DB_WATCHDOG_APP_RESTART=true`) after APP_RESTART_RUNS consecutive flagged runs.
# The health wait is separate from the corruption path's 90 s: on a ramdisk box a backend boot is
# minutes (measured 377 s on KBR with a 3.19 GB seed), and a 90 s ceiling would report every honest
# restart as failed.
APP_RESTART=$(env_get DB_WATCHDOG_APP_RESTART)
case "$APP_RESTART" in true|1|yes) APP_RESTART=true ;; *) APP_RESTART=false ;; esac
APP_RESTART_RUNS=$(env_get DB_WATCHDOG_APP_RESTART_RUNS);          APP_RESTART_RUNS=$(_num "$APP_RESTART_RUNS" 2)
APP_RESTART_COOLDOWN=$(env_get DB_WATCHDOG_APP_RESTART_COOLDOWN_SEC); APP_RESTART_COOLDOWN=$(_num "$APP_RESTART_COOLDOWN" 1800)
APP_HEALTH_WAIT=$(env_get DB_WATCHDOG_APP_HEALTH_WAIT_SEC);        APP_HEALTH_WAIT=$(_num "$APP_HEALTH_WAIT" 600)
APP_STREAK="$WD/.app_down_streak"; APP_RESTART_AT="$WD/.app_restart_at"; APP_FAILS="$WD/.app_fails"
EVENTS_LEVEL=$(env_get DB_WATCHDOG_EVENTS_LEVEL)       # critical (default) | all — a typo never
case "$(printf '%s' "${EVENTS_LEVEL:-critical}" | tr 'A-Z' 'a-z')" in   # silently widens the record
  all) EVENTS_LEVEL=all ;;
  *) EVENTS_LEVEL=critical ;;
esac

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

[ "$ENABLED" = "true" ] || { ACTION="disabled"; say "disabled (DB_WATCHDOG_ENABLED=false) — set it true in .env to enable"; exit 0; }

# ── ramdisk policy: what this feature checks when the live DB is in RAM ──────────────────
# Historically the watchdog SKIPPED itself whenever RAMDISK_ENABLED=true: the live DB is tmpfs and
# <run-dir>/sqlite_data/centrallog.db is only the periodic sync copy. That reasoning holds for RECOVERY
# (promoting the copy back over a healthy RAM copy would replace live data with stale data) but it never
# held for DETECTION: the copy is exactly what `init_db` re-seeds /dev/shm from after a restart, and KBR
# was already caught once with a sync that died mid-write (2026-10-09, leaving centrallog.db.tmp). A
# damaged sync copy is a real failure mode on a ramdisk box and nothing checked it.
#   DB_WATCHDOG_RAMDISK_MODE = skip  DEFAULT — the old behaviour; no box changes until it is set
#                              = disk  check the sync copy exactly as a disk box does
#                              = live  quick_check the LIVE RAM DB through the backend container
#                              = both  disk integrity_check AND live quick_check
# AUTO-RECOVERY on a ramdisk box is REFUSED unless the operator opts into the restart-only form with
# `DB_WATCHDOG_RAMDISK_RESTART=true`; either way the reason is logged.
# ⚠ RESTART-ONLY recovery on a ramdisk box is opt-in: `DB_WATCHDOG_RAMDISK_RESTART=true`.
# The watchdog's recovery sequence is already restart-only — it stops the writers, starts the backend
# (whose own boot-time validation re-seeds/heals the RAM copy from the disk file), then starts the
# poller. It never writes a data file itself. What the old blanket refusal bought is the guarantee that
# a ramdisk box is never *reverted* silently: re-seeding the RAM copy replays the disk file, which is up
# to RAMDISK_SYNC_INTERVAL_SECONDS behind, so accepting this form of recovery accepts up to that much
# data loss on a damaged RAM DB. That is an operator decision, so the default stays `false` and refusal
# keeps today's behaviour. What this knob buys: the app comes back on its own instead of waiting for a
# human — which is exactly what a cron-run safety net is for (a root-run repair is impossible from cron
# on KBR: `sudo` there requires a password).
RAMDISK_RESTART=$(env_get DB_WATCHDOG_RAMDISK_RESTART)
case "$RAMDISK_RESTART" in true|1|yes) RAMDISK_RESTART=true ;; *) RAMDISK_RESTART=false ;; esac
RAMDISK_ON=$(env_get RAMDISK_ENABLED)
case "$RAMDISK_ON" in true|1|yes) RAMDISK_ON=1 ;; *) RAMDISK_ON=0 ;; esac
RAM_MODE=$(env_get DB_WATCHDOG_RAMDISK_MODE)
case "$RAM_MODE" in skip|disk|live|both) ;; *) RAM_MODE=skip ;; esac
if [ "$RAMDISK_ON" = 1 ]; then
  case "$RAM_MODE" in
    skip)
      logl "SKIP RAMDISK_ENABLED=true — live DB is in RAM; set DB_WATCHDOG_RAMDISK_MODE=disk|live|both to check the sync copy and/or the live DB anyway"
      ACTION="skip_ramdisk"
      say "skipped — RAMDISK_ENABLED=true (live DB is in RAM, not on disk)"; exit 0 ;;
    *)
      if [ "$AUTORECOVER" = "true" ] && [ "$RAMDISK_RESTART" = true ]; then
        logl "NOTE ramdisk mode=$RAM_MODE — recovery is RESTART-ONLY: stop poller+backend, start the backend (its own boot-time validation re-seeds/heals the RAM copy from the disk file), then verify the LIVE RAM DB through the container. It never writes or promotes a data file, and it never heals a damaged RAM DB from a damaged disk copy — that still needs 'sudo $SELF_DIR/recover_db.sh $RUN'. ⚠ Re-seeding replays the disk copy, which is up to RAMDISK_SYNC_INTERVAL_SECONDS behind"
      elif [ "$AUTORECOVER" = "true" ]; then
        logl "NOTE ramdisk mode=$RAM_MODE — auto-recovery REFUSED for this run: the live DB is in RAM, so the disk copy is never promoted back over it (set DB_WATCHDOG_RAMDISK_RESTART=true to allow the restart-only form)"
        AUTORECOVER=false
      fi
      ;;
  esac
fi

BE=$(cid backend); PO=$(cid poller)
# No backend container = the stack is down (or not deployed). The run dir was already
# validated to have a compose file above, so this is not an error — just skip. A
# deliberate `start.sh down` must neither spam errors nor be resurrected here.
if [ -z "$BE" ]; then
  logl "skip: stack not running (no backend container)"
  ACTION="skip_stack"
  say "stack is not running — nothing to do (will not resurrect a deliberate 'down')"; exit 0
fi

# ── app liveness: is the backend actually serving? ────────────────────────
# The corruption signals (integrity_check, backend `malformed` lines) are silent for a wedged or
# half-started stack: the file is fine, the app is not. This reads the same health status Docker
# itself computes, so it costs one `docker inspect` and needs no new probe of the app.
_be_state=$(docker inspect -f '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$BE" 2>/dev/null)
_po_state=""; [ -n "$PO" ] && _po_state=$(docker inspect -f '{{.State.Status}}' "$PO" 2>/dev/null)
APP_DOWN=0; APP_DOWN_WHY=""
case "$_be_state" in
  *"unhealthy"*)   APP_DOWN=1; APP_DOWN_WHY="backend $_be_state" ;;
  exited*)         APP_DOWN=1; APP_DOWN_WHY="backend status exited" ;;
  dead*|created*)  APP_DOWN=1; APP_DOWN_WHY="backend status ${_be_state%%|*} (a recreate that never finished)" ;;
  restarting*)     APP_DOWN=1; APP_DOWN_WHY="backend is crash-looping" ;;
esac
case "$_po_state" in
  exited|dead|created) APP_DOWN=1; APP_DOWN_WHY="${APP_DOWN_WHY:+$APP_DOWN_WHY; }poller status $_po_state" ;;
esac
if [ "$APP_DOWN" = 1 ]; then
  _as=$(( $(cat "$APP_STREAK" 2>/dev/null || echo 0) + 1 )); echo "$_as" > "$APP_STREAK" 2>/dev/null || true
  logl "WARN app not serving: $APP_DOWN_WHY (consecutive flagged runs: $_as)"
  if [ "$APP_RESTART" = true ] && [ "$_as" -ge "$APP_RESTART_RUNS" ] 2>/dev/null; then
    _nowa=$(date +%s); _lasta=$(cat "$APP_RESTART_AT" 2>/dev/null || echo 0)
    if [ $(( _nowa - _lasta )) -lt "$APP_RESTART_COOLDOWN" ]; then
      logl "APP RESTART suppressed (cooldown, last $(date -u -d @"$_lasta" +%H:%M:%SZ))"
      ACTION="app_down_cooldown"
      say "app is not serving; the restart is inside its cooldown window"; exit 1
    fi
    echo "$_nowa" > "$APP_RESTART_AT" 2>/dev/null || true
    logl "APP RESTART: $APP_DOWN_WHY — stop poller+backend → start backend → wait healthy (max ${APP_HEALTH_WAIT}s) → start poller"
    dc stop poller backend >> "$LOG" 2>&1
    dc start backend >> "$LOG" 2>&1
    BE=$(cid backend); waited=0
    while [ "$waited" -lt "$APP_HEALTH_WAIT" ]; do
      h=$(docker inspect -f '{{.State.Health.Status}}' "$BE" 2>/dev/null || echo unknown)
      [ "$h" = "healthy" ] && break
      sleep 5; waited=$(( waited + 5 ))
    done
    dc start poller >> "$LOG" 2>&1
    sleep 10
    _fin=$(docker inspect -f '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$BE" 2>/dev/null)
    case "$_fin" in
      running\|healthy|running\|none)
        logl "APP RESTART ok: backend $_fin after ${waited}s"; echo 0 > "$APP_STREAK" 2>/dev/null || true
        echo 0 > "$APP_FAILS" 2>/dev/null || true
        ACTION="app_restarted"
        say "app was not serving — restarted, now $_fin"
        telegram_notify "DB watchdog: the app was not serving ($APP_DOWN_WHY) and was restarted — backend now $_fin."
        exit 0 ;;
    esac
    _af=$(( $(cat "$APP_FAILS" 2>/dev/null || echo 0) + 1 )); echo "$_af" > "$APP_FAILS" 2>/dev/null || true
    logl "APP RESTART FAILED (attempt $_af): backend still $_fin after ${waited}s"
    ACTION="app_restart_failed"
    say "app was not serving and the restart did not fix it — see $LOG"
    telegram_notify "DB watchdog: the app was not serving ($APP_DOWN_WHY) and a restart did NOT fix it (backend still $_fin). Manual: cd $RUN && ./start.sh restart"
    exit 1
  fi
  # No restart taken (opt-out, or the streak has not reached the threshold yet): keep going so the DB
  # story is still checked this run — but a serving verdict must not be recorded as plain `healthy`.
else
  echo 0 > "$APP_STREAK" 2>/dev/null || true
fi

# ── how this run talks to SQLite ─────────────────────────────────────────────────────
# Two routes: the host `sqlite3` CLI, or python inside the backend container (the images ship NO sqlite3
# binary — measured — but python's sqlite3 module is there, and the container is the user that owns the DB
# files, so it can create the -shm a read-only open needs).
# ⚠ A MISSING TOOL IS NOT EVIDENCE ABOUT THE DATABASE. Measured on KBR 2026-10-12: no sqlite3 on that host
# and PATH is pinned at the top of this script. Before this block existed, `res` captured the shell's own
# "sqlite3: command not found" text — neither `ok` nor empty — `confirmed` then fired on file_status alone,
# and with DB_WATCHDOG_AUTORECOVER=true (KBR's setting) the next step of that path stops backend+poller and
# promotes a backup over a healthy 2.6 GB database. Now: use the container route, or REFUSE the run.
HAVE_SQLITE3=1; command -v sqlite3 >/dev/null 2>&1 || HAVE_SQLITE3=0
PROBE_VIA_CONTAINER=$(env_get DB_WATCHDOG_PROBE_VIA_CONTAINER)
case "$PROBE_VIA_CONTAINER" in true|1|yes) PROBE_VIA_CONTAINER=true ;; *) PROBE_VIA_CONTAINER=false ;; esac
# The container route is used when the operator asked for it, or when the host has no CLI at all.
USE_CONTAINER=0
if [ "$PROBE_VIA_CONTAINER" = true ] || [ "$HAVE_SQLITE3" = 0 ]; then USE_CONTAINER=1; fi
# A host with no `sqlite3` CLI is NOT a reason to skip detection — the container route covers it, and a box
# like KBR (no sqlite3, air-gapped, so no easy install) otherwise gets no safety net at all. What the CLI
# is still required for is RECOVERY, and that is refused explicitly below (error_no_sqlite3) rather than
# attempted with a tool that does not exist.

if [ "$HAVE_SQLITE3" = 0 ]; then
  logl "NOTE sqlite3 CLI absent on this host — every SQLite check runs inside the backend container instead"
fi
DB_IN="/data/$(basename "$DB")"                    # ./sqlite_data:/data in BOTH composes
RAM_IN=$(env_get RAMDISK_PATH); [ -n "$RAM_IN" ] || RAM_IN="/ramdisk/$(basename "$DB")"
LIVECHECK=""; LIVEBAD=0

# ── signals ──────────────────────────────────────────────────────────────
# Text that means "the tool could not reach a container" — it says NOTHING about the database.
container_gone() {
  case "$1" in
    *"No such container"*|*"no such container"*|*"not running"*|*"Traceback"*|*"Error response from daemon"*|*"permission denied"*|*"command not found"*|*"executable file not found"*) return 0 ;;
    *) return 1 ;;
  esac
}
# ⚠ A watchdog run in ramdisk mode=both lasts MINUTES (live quick_check on a multi-GB RAM DB, then a
# DB-sized snapshot): on KBR the cron tick at 07:30:01 produced a live check at 07:32:33 and a snapshot
# at 07:37:13. `cid backend` is resolved once at the top of the run, so a deploy recreate during it
# invalidates the id, and every later `docker exec` answers `Error response from daemon: No such
# container: <id>`. Measured three times (2026-10-30T05:42:41Z, 2026-11-01T07:32:33Z, 08:02:17Z) — each
# one logged as "live ramdisk DB failed quick_check", blaming the database for a docker race.
probe_container() {   # $1 = container-side path, $2 = statement (default integrity_check)
  _pcp="${1:-$DB_IN}"; _pcq="${2:-PRAGMA integrity_check;}"
  _pcrun() { docker exec "$BE" python -c "import sqlite3;c=sqlite3.connect('file:$_pcp?mode=ro',uri=True);print(c.execute('$_pcq').fetchone()[0]);c.close()" 2>&1 | head -1; }
  _pcout=$(_pcrun)
  if container_gone "$_pcout"; then
    _pcnew=$(cid backend)
    if [ -n "$_pcnew" ] && [ "$_pcnew" != "$BE" ]; then
      logl "NOTE backend container id changed mid-run (${BE:0:12} -> ${_pcnew:0:12}) — a recreate happened while this watchdog run was working; retrying through the new container"
      BE="$_pcnew"
      _pcout=$(_pcrun)
    fi
  fi
  printf '%s\n' "$_pcout"
}
backup_container() {   # online backup API run by the container's own writer, then docker cp out
  _ct="/tmp/wd-watchdog-$$.db"
  _bc=1
  docker exec "$BE" python -c "import sqlite3;s=sqlite3.connect('file:$DB_IN?mode=ro',uri=True);d=sqlite3.connect('$_ct');s.backup(d);d.close();s.close()" 2>>"$LOG" || _bc=0
  if [ "$_bc" = 1 ]; then docker cp "$BE:$_ct" "$1" 2>>"$LOG" || _bc=0; fi
  # The container-side file is DB-SIZED and sits in the container's writable layer. It is removed on
  # EVERY exit path — a failed `docker cp` must not strand one full copy of the database per attempt.
  docker exec "$BE" rm -f "$_ct" "$_ct-wal" "$_ct-shm" 2>/dev/null || true
  if [ "$_bc" = 1 ]; then return 0; fi
  return 1
}
# Probe target: the disk sync copy — except in mode=live, where it is the LIVE RAM database, read through
# the container that owns it (a host read of the /dev/shm subdir needs root; the watchdog runs as the operator).
if [ "$RAMDISK_ON" = 1 ] && [ "$RAM_MODE" = live ]; then
  res=$(probe_container "$RAM_IN" "PRAGMA quick_check;")
  LIVECHECK="$res"
  _probe_maybe=1
elif [ "$HAVE_SQLITE3" = 1 ]; then
  res=$(sqlite3 "file:$DB?mode=ro" "PRAGMA integrity_check;" 2>&1 | head -1)
  _probe_maybe=""
else
  res=$(probe_container "$DB_IN"); _probe_maybe=1
fi
# One `docker logs` read, two counters: `malformed` is damage, `database is locked` is contention.
# They must never be conflated — only the first one may ever lead to a recovery.
_BE_LOG=$(docker logs --since "${APP_ERR_MIN}m" "$BE" 2>&1)
app_errs=$(printf '%s\n' "$_BE_LOG" | grep -c "disk image is malformed")
app_lock_errs=$(printf '%s\n' "$_BE_LOG" | grep -c "database is locked")
# C2 (BACKLOG #37's other half). A read-only open of a WAL database must CREATE -shm, so on a root-owned
# data dir with the sidecars gone (a quiet DB) the direct probe can NEVER answer — and neither can .backup.
# The container that owns the writers can open the same file, so probe there and snapshot there too.
# ⚠ The fix is never chown/chmod on sqlite_data: a -shm the operator creates is one the root writers then
#   cannot open. Inside the container the sidecars are created by the user that already owns the DB.
# A lost write lock is a BENIGN probe shape too: on a busy WAL database the watchdog's own read-only
# open can lose the lock (it must read -wal and may have to create -shm). Before this, only
# `readonly database` / `command not found` / empty were treated as benign, so a `database is locked`
# probe error skipped the container-side retry — the route that answers `ok` on a healthy DB — and the
# run fell into the corruption classifier. Measured on the Lite box 2026-11-01T12:50:01Z: exactly that
# path stopped poller+backend for 16 s on a database that was serving 200s, with app_errs=0.
case "$res" in *"readonly database"*|*"command not found"*|*"database is locked"*|"") _probe_maybe=1 ;; *) _probe_maybe="" ;; esac
if [ "$USE_CONTAINER" = 1 ] && [ "$res" != "ok" ] && [ -n "$_probe_maybe" ] && [ "$RAM_MODE" != live ]; then
  _direct_res="$res"
  cres=$(probe_container "$DB_IN")
  if [ "$cres" = "ok" ]; then
    res="ok"
    logl "OK probe via container: direct open failed [$_direct_res] — the container-side read answered ok"
  fi
fi
# `both`: the live DB is checked in addition, and a live failure is corruption on its own terms — the sync
# copy can read perfectly clean while the database that answers every request is damaged.
if [ "$RAMDISK_ON" = 1 ] && [ "$RAM_MODE" = both ]; then
  LIVECHECK=$(probe_container "$RAM_IN" "PRAGMA quick_check;")
fi
if [ "$RAMDISK_ON" = 1 ] && [ "$RAM_MODE" = live ] && [ "$res" != "ok" ]; then LIVEBAD=1; fi
if [ -n "$LIVECHECK" ] && [ "$LIVECHECK" != "ok" ]; then
  if container_gone "$LIVECHECK"; then
    # A docker failure is not a database verdict and must not confirm corruption (the #65 rule: a
    # missing tool is never evidence about the thing the tool was meant to measure).
    logl "WARN live ramdisk DB check UNVERIFIED: the container route did not answer [$(printf '%s' "$LIVECHECK" | tr -d '\n' | cut -c1-160)] — this says nothing about the database and does NOT confirm corruption"
  else
    LIVEBAD=1
    logl "WARN live ramdisk DB failed quick_check: [$(printf '%s' "$LIVECHECK" | tr -d '\n' | cut -c1-160)]"
  fi
fi
# C4 tunables + probe-failure streak state (fired in the not_confirmed branch below).
# PROBE_FAIL_ALERT = how long a silent streak is tolerated before it is said out loud (0 = never alert).
# PROBE_ALERT_REPEAT_SEC = the slow repeat once it IS loud: at most one alert per window (default 1 day)
# while the streak continues — a permanently failing box must not emit one message per cron run.
PROBE_FAILS="$WD/.probe_fails"
PROBE_ALERT_AT="$WD/.probe_alert_at"
LOCK_ALERT_AT="$WD/.lock_alert_at"
CONTENDED=0
PROBE_FAIL_ALERT=$(_num "$(env_get DB_WATCHDOG_PROBE_FAIL_ALERT)" 3)
PROBE_ALERT_REPEAT=$(_num "$(env_get DB_WATCHDOG_PROBE_ALERT_REPEAT_SEC)" 86400)
probe_cause() {   # name the failure instead of quoting a raw error string
  case "$1" in
    *"readonly database"*) echo "read-only open cannot create -shm (typically the data dir is root-owned and the WAL sidecars are absent while the DB is idle)" ;;
    *"database is locked"*) echo "the read-only open lost the SQLite write lock to live writers (contention, not damage)" ;;
    *"no such file"*|*"unable to open"*) echo "the database file could not be opened at all" ;;
    *) _c=$(printf '%s' "$1" | tr -d '\n' | cut -c1-160)
       if [ -n "$_c" ]; then echo "$_c"; else echo "empty error text (failure class unnamed — see the backend log)"; fi ;;
  esac
}
if [ "$res" = "ok" ]; then
  probe_fails=0; echo 0 > "$PROBE_FAILS" 2>/dev/null || true
  rm -f "$PROBE_ALERT_AT" 2>/dev/null || true   # a clean probe re-arms the next streak alert
else
  probe_fails=$(( $(cat "$PROBE_FAILS" 2>/dev/null || echo 0) + 1 ))
  echo "$probe_fails" > "$PROBE_FAILS" 2>/dev/null || true
fi

# ── app-level contention: a clean FILE with a database nobody can write to ─────────────
# #76. Both corruption signals are silent during a lock storm: integrity_check passes (the file is
# fine) and the backend logs no `disk image is malformed` — yet every request fails. That is the
# "the DB is dead and the watchdog did nothing" shape, and it is a detection gap, not a malfunction.
# Detection + alert only: `stop the writers` cannot release a lock another process holds, so a
# recovery here would just add an outage to the outage. The row is recorded (ACTION=app_contention)
# on an otherwise-healthy run; when a louder problem exists (not_confirmed / confirmed), that action
# stands and the WARN line + the Telegram alert still fire.
if [ "$LOCK_ALERT" -gt 0 ] && [ "${app_lock_errs:-0}" -ge "$LOCK_ALERT" ] 2>/dev/null; then
  CONTENDED=1
  _nowl=$(date +%s)
  _lastl=$(stat -c%Y "$LOCK_ALERT_AT" 2>/dev/null || echo 0)
  if [ $(( _nowl - _lastl )) -ge "$LOCK_ALERT_REPEAT" ]; then
    logl "WARN app-level DB contention: locked=$app_lock_errs backend 'database is locked' errors in the last ${APP_ERR_MIN} min — the file reads clean (probe=[$(printf '%s' "${res:-}" | tr -d '\n' | cut -c1-100)]), so this is contention, not damage; NO recovery is attempted"
    telegram_notify "DB watchdog: $app_lock_errs 'database is locked' backend errors in the last ${APP_ERR_MIN} min. The database file itself reads clean, so NO recovery was attempted — this is SQLite write contention, not corruption."
    touch "$LOCK_ALERT_AT" 2>/dev/null || true
  fi
fi

# ── healthy fast-path: file reads ok AND backend not erroring → snapshot ──
# ⚠ `LIVEBAD` must gate this exit or `DB_WATCHDOG_RAMDISK_MODE=both` is decorative: the mode exists to
# catch a damaged LIVE RAM database while the lagging disk copy reads clean, but the confirmed block
# below only runs when this exits false. Measured on KBR: three live-check failures all logged a WARN
# and the run then continued to `OK integrity=ok app_errs=0 snapshot=…` — a healthy verdict with a
# flagged live DB. (On a ramdisk box auto-recovery is already forced off, so confirming there means
# forensics + an alert, never a restart.)
if [ "$res" = "ok" ] && [ "$app_errs" -eq 0 ] && [ "$LIVEBAD" != 1 ]; then
  # C1 (BACKLOG #37 + #38, 2026-10-11). Two changes, one mechanism:
  # (1) The retry cadence is keyed on the time of the last ATTEMPT
  #     ($WD/.last_snap_attempt), NOT on the newest snapshot FILE. The file-based gate had a
  #     second and worse failure mode than the recorded suppression: a failed .backup left its
  #     0-byte dst behind (the same defect that produced the 9 empties on the Lite box), and
  #     removing that empty file — which this change does — would have opened the file gate on
  #     EVERY run: 144 attempts/day against a permanently failing source, and 144 record rows.
  #     Keyed on the attempt time, the cadence is one per 3300 s whatever the failure mode.
  # (2) A snapshot is ACCEPTED only when it is at least DB_WATCHDOG_SNAPSHOT_MIN_BYTES and has
  #     a sqlite_master. A 0-byte file passes `PRAGMA integrity_check` (#38), so size + schema
  #     is the acceptance floor; a rejected file is removed, never left to age or to gate.
  # The snapshot's ACCEPTANCE checks (size + sqlite_master + integrity) all run against the host copy of
  # the file, and the container cannot see the run dir — so a box with no host `sqlite3` takes NO snapshots.
  # Detection, records and alerts still work there; saying so is honest, while faking the checks is not.
  SNAP_OK=1
  if [ "$HAVE_SQLITE3" = 0 ]; then
    SNAP_OK=0
    logl "NOTE snapshot SKIPPED: the acceptance checks need the host sqlite3 CLI (the container cannot see the run dir). Detection, records and alerts still run"
  fi
  _lasttry=$(stat -c%Y "$WD/.last_snap_attempt" 2>/dev/null || echo 0)
  if [ "$SNAP_OK" = 1 ] && { [ "$_lasttry" = "0" ] || [ $(( $(date +%s) - _lasttry )) -ge 3300 ]; }; then
    dst="$SNAP/centrallog.$(date -u +%Y%m%dT%H%M%SZ).db"
    touch "$WD/.last_snap_attempt" 2>/dev/null || true   # the gate moves BEFORE the attempt runs
    # The direct attempt's own stderr was written to the log unlabelled (measured on the Lite box
    # 2026-11-01T16:58Z: a bare `Error: database is locked` line between two labelled ones), and the
    # container-route sentence then claimed the cause was `-shm` when it was a lost write lock. Capture
    # it and name it, so a reader knows which route failed and why.
    _derr=$(mktemp)
    _derr_text() {   # first line of the captured stderr, capped, or an explicit "no error text"
      local _t; _t=$(head -1 "$1" 2>/dev/null)
      if [ -n "$_t" ]; then printf '%s' "$_t" | cut -c1-120; else printf 'no error text'; fi
    }
    if sqlite3 "file:$DB?mode=ro" ".backup '$dst'" 2>"$_derr"; then
      _snap_from=direct
      if [ -s "$_derr" ]; then
        logl "NOTE direct snapshot attempt succeeded but printed: $(_derr_text "$_derr")"
      fi
    elif [ "$PROBE_VIA_CONTAINER" = true ] && backup_container "$dst"; then
      # C2: the container's own writer can open the file — copy its online backup out.
      _snap_from=container
      logl "OK snapshot taken INSIDE the backend container (the direct read-only attempt failed: $(_derr_text "$_derr"))"
    else
      SNAPSTAT="backup_failed"
      # The empty dst is deleted here — that was #37's fingerprint. NO snapshot file survives a
      # failed attempt on any branch (third instance of the absence rule in this file).
      logl "WARN .backup command failed ($(_derr_text "$_derr")) — no partial snapshot left behind"
      rm -f "$dst" "$dst-wal" "$dst-shm"
      _snap_from=""
    fi
    rm -f "$_derr"
    if [ -n "$_snap_from" ]; then
      sqlite3 "$dst" "PRAGMA journal_mode=DELETE;" >/dev/null 2>>"$LOG"; rm -f "$dst-wal" "$dst-shm"
      _snap_size=$(stat -c%s "$dst" 2>/dev/null || echo 0)
      _snap_tables=$(sqlite3 "file:$dst?mode=ro" 'SELECT count(*) FROM sqlite_master;' 2>/dev/null || echo 0)
      if [ "$_snap_size" -lt "$SNAP_MIN_BYTES" ] 2>/dev/null || [ "$_snap_tables" -le 0 ] 2>/dev/null; then
        SNAPSTAT="too_small"; SNAPBYTES=$_snap_size
        logl "WARN snapshot REJECTED: size=$_snap_size tables=$_snap_tables (floor $SNAP_MIN_BYTES) — removed"
        rm -f "$dst" "$dst-wal" "$dst-shm"
      elif [ "$(sqlite3 "file:$dst?mode=ro" 'PRAGMA integrity_check;' 2>&1 | head -1)" = "ok" ]; then
        SNAPSTAT="ok"; SNAPBYTES=$_snap_size
        logl "OK integrity=ok app_errs=0 snapshot=$(basename "$dst") size=$_snap_size via=$_snap_from"
      else
        SNAPSTAT="own_check_failed"
        logl "WARN snapshot failed own integrity check, removed"; rm -f "$dst" "$dst-wal" "$dst-shm"
      fi
    fi
    # Prune on EVERY branch that touched $SNAP (#38): the prune used to sit inside the success
    # arm only, so a box that keeps failing grew its snapshot dir without bound.
    # DB_WATCHDOG_SNAP_KEEP (default 24) bounds it — each snapshot is DB-SIZED, so on a
    # multi-GB box the default is a disk-space decision, not a free one.
    ls -t "$SNAP"/centrallog.*.db 2>/dev/null | tail -n +$((SNAP_KEEP + 1)) | xargs -r rm -f
  else
    if [ "$SNAP_OK" = 0 ]; then SNAPSTAT="not_attempted"; else SNAPSTAT="skipped_gate"; fi
  fi
  if [ "$APP_DOWN" = 1 ]; then
    ACTION="app_down"
    say "the database file reads clean but the app is NOT serving ($APP_DOWN_WHY) — DB_WATCHDOG_APP_RESTART=true makes this watchdog restart it"
  elif [ "$CONTENDED" = 1 ]; then
    ACTION="app_contention"
    say "file reads clean, but $app_lock_errs backend 'database is locked' errors in ${APP_ERR_MIN} min — contention, not damage; no recovery attempted"
  else
    ACTION="healthy"
    say "healthy — integrity ok, app_errs=0"
  fi
  exit 0
fi

# ── classify: real malformed vs a benign probe error (WAL DB w/ no -shm) ──
# A MISSING file is its own state (the SD wiped it), not "malformed": the action
# is the same (autoheal promotes the newest valid backup) but the forensics must
# say so.
if [ "$res" = "ok" ]; then
  # In mode=both the sync copy can read perfectly clean while the LIVE RAM database that answers every
  # request is damaged. Say which one failed, so the record names the evidence.
  if [ "$LIVEBAD" = 1 ]; then
    file_status="live-check-failed: $(printf '%s' "${LIVECHECK:-}" | tr -d '\n' | cut -c1-100)"
  else
    file_status="ok"
  fi
elif [ ! -f "$DB" ]; then
  file_status="missing"
else
  # ⚠ `cp` of the main file is NOT a copy of the database. In WAL mode every recent commit lives in
  # centrallog.db-wal, so a main-file-only copy is a snapshot of some EARLIER checkpoint — and if the
  # copy lands while a checkpoint is rewriting the main file, that one file can be structurally
  # inconsistent. `PRAGMA integrity_check` then reports it as e.g. `wrong # of entries in index
  # ix_device_health_device_time` on a database that is serving requests normally. Measured on this
  # fleet 2026-11-01T12:50:01Z (Lite): that verdict stopped poller+backend for 16 s while the backend
  # was logging 200s on /topology and app_errs=0. Reproduced in the negative: 40 main-file-only copies
  # taken from live WAL databases (un-checkpointed WAL up to 7 MB) ALL read `ok` — the copy is blind to
  # whatever the app is currently doing, and only occasionally catches the mid-checkpoint state that
  # fabricates a fault. So the copy is no longer the verdict: the container-side read of the SAME file
  # the app uses (WAL included) decides, and a copy that disagrees is reported, not acted on. Where no
  # container route exists the copy is still the only evidence available and is labelled as such.
  _copy_status=""
  if [ "$HAVE_SQLITE3" = 1 ]; then
    cp "$DB" "/tmp/wd_verify_$PROJ.db" 2>/dev/null
    _copy_status=$(sqlite3 "/tmp/wd_verify_$PROJ.db" "PRAGMA integrity_check;" 2>&1 | head -1)
    rm -f "/tmp/wd_verify_$PROJ.db"*
  fi
  if [ "$USE_CONTAINER" = 1 ]; then
    file_status=$(probe_container "$DB_IN")
    if container_gone "$file_status"; then
      # The container read itself failed — that is evidence about the TOOL, not about the database.
      _cerr=$(printf '%s' "$file_status" | tr -d '\n' | cut -c1-100)
      if [ -n "$_copy_status" ]; then
        file_status="$_copy_status"
        logl "WARN container-side read unavailable [$_cerr] — falling back to the main-file-only copy, which sees no WAL content"
      else
        file_status="unverified"
        logl "ERROR no verification route answered (container read failed: [$_cerr]; no host sqlite3) — corruption is neither confirmed nor ruled out; NO recovery attempted"
      fi
    elif [ "$file_status" = "ok" ] && [ -n "$_copy_status" ] && [ "$_copy_status" != "ok" ]; then
      logl "WARN main-file-only copy disagrees [$(printf '%s' "$_copy_status" | tr -d '\n' | cut -c1-120)] — the container-side read of the live DB (WAL included) says ok, and a copy of ONE FILE of a WAL database is not a corruption verdict: this run does NOT confirm corruption"
    fi
  else
    file_status="$_copy_status"
    if [ -z "$file_status" ]; then
      file_status="unverified"
      logl "ERROR no host sqlite3 and DB_WATCHDOG_PROBE_VIA_CONTAINER is off — nothing verified the file; corruption is neither confirmed nor ruled out"
    else
      logl "NOTE container route not enabled — file_status is the main-file-only copy, which cannot see un-checkpointed WAL content"
    fi
  fi
fi

confirmed=0
[ "$app_errs" -ge "$APP_ERR_THRESHOLD" ] && confirmed=1
case "$file_status" in
  ok) ;;
  unverified) ;;   # nothing answered the question — confirming on silence is the #65 missing-tool trap
  *) confirmed=1 ;;
esac
[ "$LIVEBAD" = 1 ] && confirmed=1     # a damaged LIVE ramdisk DB is corruption whatever the copy says

if [ "$confirmed" -eq 0 ]; then
  logl "WARN no action: res=[$res] file_status=ok app_errs=$app_errs (<${APP_ERR_THRESHOLD}) — not confirmed"
  ACTION="not_confirmed"
  # C4 (#37's silent half): a probe error the `/tmp` copy cannot confirm used to be one log line
  # among many, forever. Say it out loud once the streak crosses the threshold, NAME the cause, and
  # repeat only once per PROBE_ALERT_REPEAT_SEC while it stays broken (48 messages/day on a box whose
  # probe always fails was the alternative). PROBE_FAIL_ALERT=0 disables the alert; a clean probe
  # deletes the stamp, so the NEXT streak alerts at its own threshold.
  _now=$(date +%s)
  _lastalert=$(stat -c%Y "$PROBE_ALERT_AT" 2>/dev/null || echo 0)
  if [ "$PROBE_FAIL_ALERT" -gt 0 ] && [ "${probe_fails:-0}" -ge "$PROBE_FAIL_ALERT" ] 2>/dev/null && \
     [ $(( _now - _lastalert )) -ge "$PROBE_ALERT_REPEAT" ]; then
    _cause=$(probe_cause "$res")
    logl "WARN probe failed $probe_fails runs in a row: $_cause"
    telegram_notify "DB watchdog: the read-only probe has failed $probe_fails runs in a row ($_cause). Detection still works — the /tmp copy is verified — but the watchdog cannot take its own snapshot."
    touch "$PROBE_ALERT_AT" 2>/dev/null || true
  fi
  say "no confirmed corruption — file verifies clean, app_errs=$app_errs (<${APP_ERR_THRESHOLD})"
  exit 0
fi

# ── confirmed corruption ─────────────────────────────────────────────────
logl "CONFIRMED corruption: probe=[$res] file_status=[$file_status] app_errs=$app_errs"
ACTION="confirmed"
say "CORRUPTION confirmed (file=$file_status, backend malformed errors=$app_errs)"
stamp=$(date -u +%Y%m%dT%H%M%SZ); d="$FOR/$stamp"; mkdir -p "$d"
{ echo "=== $(ts) $PROJ ==="; echo "probe=[$res] file_status=[$file_status] app_errs=$app_errs"
  echo "--- ls ---"; ls -la --time-style=+%H:%M:%S "$DATA"; } > "$d/state.txt" 2>&1
docker logs --tail 400 "$BE" > "$d/backend.log" 2>&1
[ -n "$PO" ] && docker logs --tail 400 "$PO" > "$d/poller.log" 2>&1

# ⚑ RECOVERY needs the host `sqlite3` CLI for every step — candidate gating, VACUUM INTO, the final
# verification — while the container route covers DETECTION only. No CLI means refuse the repair, after the
# detection has already produced forensics and an alert. `recover_db.sh` carries the same guard for the
# manual path, so the operator gets the same sentence either way.
if [ "$AUTORECOVER" = "true" ] && [ "$HAVE_SQLITE3" = 0 ]; then
  logl "ERROR corruption confirmed but sqlite3 is not installed on this host — auto-recovery REFUSED (candidate gating and VACUUM INTO need it). Forensics saved to $d; install sqlite3, then run sudo $SELF_DIR/recover_db.sh"
  ACTION="error_no_sqlite3"
  say "corruption confirmed, but this host has no sqlite3 — auto-recovery refused; forensics saved to $d"
  telegram_notify "CORRUPTION detected (probe=[$res] file_status=[$file_status]) but auto-recovery is REFUSED: this host has no sqlite3 CLI. Forensics: $d"
  exit 1
fi
if [ "$AUTORECOVER" != "true" ]; then
  logl "AUTORECOVER=off — detected + forensics saved to $d; NOT restarting"
  ACTION="confirmed_no_autorecover"
  say "auto-recovery is OFF — forensics saved to $d; run 'sudo $SELF_DIR/recover_db.sh' to repair"
  telegram_notify "CORRUPTION detected (probe=[$res] file_status=[$file_status]). Auto-recovery is OFF — manual repair needed. Forensics: $d"
  exit 1
fi
if [ -f "$ESC" ]; then
  logl "ESCALATED flag present ($ESC) — auto-recovery disabled; needs manual attention. rm the file to re-arm."
  ACTION="confirmed_escalated_breaker"
  say "escalated after repeated failures — run 'sudo $SELF_DIR/recover_db.sh', then 'rm $ESC'"; exit 1
fi
now=$(date +%s); last=$(cat "$COOL" 2>/dev/null || echo 0)
if [ $(( now - last )) -lt "$RECOVER_COOLDOWN" ]; then
  logl "RECOVER suppressed (cooldown, last $(date -u -d @"$last" +%H:%M:%SZ))"
  ACTION="confirmed_cooldown"
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
# The same ownership wall as #37: on a root-owned data dir with no sidecars present, the host
# read-only open can NEVER answer — so without this the recovery could only ever be judged by the
# backend's `malformed` count, and the log printed probe=[…readonly database (8)] next to "RECOVER ok".
case "$res2" in
  *"readonly database"*|*"database is locked"*|"")
    if [ "$USE_CONTAINER" = 1 ]; then
      _c2=$(probe_container "$DB_IN")
      if [ "$_c2" = "ok" ]; then
        logl "OK RECOVER verification via container: direct open failed [$(printf '%s' "$res2" | tr -d '\n' | cut -c1-100)] — the container-side read of the live DB answers ok"
        res2="ok"
      fi
    fi
    ;;
esac
# On a ramdisk box the file the app actually uses is the RAM copy, so the recovery is only
# "recovered" if THAT reads clean. Quick-checked through the container (the host cannot read the
# container-owned /dev/shm subdir). This is what makes the restart-only form honest: if the RAM DB is
# still damaged after the boot-time re-seed, say so and send the operator to the root-run repair
# instead of logging success.
live2=""
if [ "$RAMDISK_ON" = 1 ] && { [ "$RAM_MODE" = live ] || [ "$RAM_MODE" = both ]; }; then
  live2=$(probe_container "$RAM_IN" "PRAGMA quick_check;")
  logl "RECOVER verify: live RAM DB quick_check=[$(printf '%s' "$live2" | tr -d '\n' | cut -c1-100)] (through the backend container)"
fi

_ok=0
if [ "$after" -eq 0 ] && { [ "$res2" = "ok" ] || docker logs --since "$SINCE" "$BE" 2>&1 | grep -q " 200 OK"; }; then _ok=1; fi
if [ -n "$live2" ] && [ "$live2" = "ok" ] && [ "$res2" != "ok" ]; then _ok=1; fi
if [ -n "$live2" ] && [ "$live2" != "ok" ]; then
  _ok=0
  logl "WARN recovery NOT confirmed: the LIVE RAM database still fails quick_check [$live2] — a restart cannot heal it, and the disk copy is what a re-seed would replay. Run 'sudo $SELF_DIR/recover_db.sh $RUN' (cron cannot do it: sudo needs a password on this host)"
fi
if [ "$_ok" = "1" ]; then
  logl "RECOVER ok: malformed(since-start)=0 probe=[$res2]$( [ -n "$live2" ] && printf ' live-quick_check=[%s]' "$(printf '%s' "$live2" | tr -d '\n' | cut -c1-100)")"; echo 0 > "$FAILS"
  ACTION="recovered"
  say "recovered OK — DB healthy again"
  telegram_notify "Auto-recovery SUCCEEDED — DB is healthy again (probe=[$res2])."
  exit 0
fi
n=$(( $(cat "$FAILS" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAILS"
logl "RECOVER FAILED (attempt $n/$MAX_FAILS): malformed(since-start)=$after probe=[$res2]"
ACTION="recover_failed"
say "recovery attempt $n/$MAX_FAILS did NOT clear it — see $LOG"
if [ "$n" -ge "$MAX_FAILS" ]; then
  touch "$ESC"
  ACTION="escalated"
  logl "ESCALATE: $n consecutive failed recoveries — auto-recovery DISABLED. Manual: check $FOR, run '$SELF_DIR/recover_db.sh $RUN', then 'rm $ESC'."
  telegram_notify "ESCALATED — $n consecutive failed recoveries, auto-recovery DISABLED. Run recover_db.sh manually, then 'rm $ESC' to re-arm. Forensics: $d"
else
  telegram_notify "Recovery attempt $n/$MAX_FAILS FAILED (probe=[$res2]). Will retry after cooldown."
fi
exit 1
