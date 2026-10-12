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
# action: healthy | not_confirmed | confirmed | confirmed_no_autorecover |
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
# In every ramdisk mode AUTO-RECOVERY is REFUSED for that run, and the reason is logged.
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
      if [ "$AUTORECOVER" = "true" ]; then
        logl "NOTE ramdisk mode=$RAM_MODE — auto-recovery REFUSED for this run: the live DB is in RAM, so the disk copy is never promoted back over it"
      fi
      AUTORECOVER=false
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
probe_container() {   # $1 = container-side path, $2 = statement (default integrity_check)
  _pcp="${1:-$DB_IN}"; _pcq="${2:-PRAGMA integrity_check;}"
  docker exec "$BE" python -c "import sqlite3;c=sqlite3.connect('file:$_pcp?mode=ro',uri=True);print(c.execute('$_pcq').fetchone()[0]);c.close()" 2>&1 | head -1
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
app_errs=$(docker logs --since "${APP_ERR_MIN}m" "$BE" 2>&1 | grep -c "disk image is malformed")
# C2 (BACKLOG #37's other half). A read-only open of a WAL database must CREATE -shm, so on a root-owned
# data dir with the sidecars gone (a quiet DB) the direct probe can NEVER answer — and neither can .backup.
# The container that owns the writers can open the same file, so probe there and snapshot there too.
# ⚠ The fix is never chown/chmod on sqlite_data: a -shm the operator creates is one the root writers then
#   cannot open. Inside the container the sidecars are created by the user that already owns the DB.
case "$res" in *"readonly database"*|*"command not found"*|"") _probe_maybe=1 ;; *) _probe_maybe="" ;; esac
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
if [ -n "$LIVECHECK" ] && [ "$LIVECHECK" != "ok" ]; then LIVEBAD=1; fi
if [ "$LIVEBAD" = 1 ]; then
  logl "WARN live ramdisk DB failed quick_check: [$(printf '%s' "$LIVECHECK" | tr -d '\n' | cut -c1-160)]"
fi
# C4 tunables + probe-failure streak state (fired in the not_confirmed branch below).
# PROBE_FAIL_ALERT = how long a silent streak is tolerated before it is said out loud (0 = never alert).
# PROBE_ALERT_REPEAT_SEC = the slow repeat once it IS loud: at most one alert per window (default 1 day)
# while the streak continues — a permanently failing box must not emit one message per cron run.
PROBE_FAILS="$WD/.probe_fails"
PROBE_ALERT_AT="$WD/.probe_alert_at"
PROBE_FAIL_ALERT=$(_num "$(env_get DB_WATCHDOG_PROBE_FAIL_ALERT)" 3)
PROBE_ALERT_REPEAT=$(_num "$(env_get DB_WATCHDOG_PROBE_ALERT_REPEAT_SEC)" 86400)
probe_cause() {   # name the failure instead of quoting a raw error string
  case "$1" in
    *"readonly database"*) echo "read-only open cannot create -shm (typically the data dir is root-owned and the WAL sidecars are absent while the DB is idle)" ;;
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

# ── healthy fast-path: file reads ok AND backend not erroring → snapshot ──
if [ "$res" = "ok" ] && [ "$app_errs" -eq 0 ]; then
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
    if sqlite3 "file:$DB?mode=ro" ".backup '$dst'" 2>>"$LOG"; then
      _snap_from=direct
    elif [ "$PROBE_VIA_CONTAINER" = true ] && backup_container "$dst"; then
      # C2: the container's own writer can open the file — copy its online backup out.
      _snap_from=container
      logl "OK snapshot taken INSIDE the backend container (the direct read-only open cannot create -shm here)"
    else
      SNAPSTAT="backup_failed"
      # The empty dst is deleted here — that was #37's fingerprint. NO snapshot file survives a
      # failed attempt on any branch (third instance of the absence rule in this file).
      logl "WARN .backup command failed — no partial snapshot left behind"; rm -f "$dst" "$dst-wal" "$dst-shm"
      _snap_from=""
    fi
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
  ACTION="healthy"
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
  if [ "$HAVE_SQLITE3" = 1 ]; then
    cp "$DB" "/tmp/wd_verify_$PROJ.db" 2>/dev/null
    file_status=$(sqlite3 "/tmp/wd_verify_$PROJ.db" "PRAGMA integrity_check;" 2>&1 | head -1)
    rm -f "/tmp/wd_verify_$PROJ.db"*
  else
    # No host CLI: the container-side read IS the verification — it is the user that owns the file and it
    # can create the -shm the operator cannot. The /tmp copy is a host-CLI convenience, not a safety rule.
    file_status=$(probe_container "$DB_IN")
    logl "NOTE /tmp-copy verification unavailable (no host sqlite3) — file_status is the container-side read"
  fi
fi

confirmed=0
[ "$app_errs" -ge "$APP_ERR_THRESHOLD" ] && confirmed=1
case "$file_status" in ok) ;; *) confirmed=1 ;; esac
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
if [ "$after" -eq 0 ] && { [ "$res2" = "ok" ] || docker logs --since "$SINCE" "$BE" 2>&1 | grep -q " 200 OK"; }; then
  logl "RECOVER ok: malformed(since-start)=0 probe=[$res2]"; echo 0 > "$FAILS"
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
