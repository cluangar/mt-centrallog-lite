#!/usr/bin/env bash
# mt-centrallog — install / remove the DB watchdog cron entry for ONE deployment.
# Scoped to a run-dir so multiple versions on one box each manage their own line.
# Called by deploy.sh / install.sh; also usable by hand (or via `db_watchdog.sh install`).
#
#   ./watchdog-cron.sh install [RUN_DIR]
#   ./watchdog-cron.sh remove  [RUN_DIR]
#   ./watchdog-cron.sh status  [RUN_DIR]
#
# RUN_DIR defaults to this script's own directory (scripts ship in the run dir).
#
# The cron is installed into the OPERATOR's crontab — the user who runs the watchdog,
# NOT root — so you can install/remove it yourself with NO sudo. When a sudo deploy
# calls this (root), it installs into the calling user's crontab via $SUDO_USER, so
# the watchdog still runs as you. `crontab -u` (needs root) is used only in that case.
set -e
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ACTION="${1:-status}"
RUN_DIR="${2:-$SELF_DIR}"
RUN_DIR="$(cd "$RUN_DIR" && pwd)"
WD_SCRIPT="$SELF_DIR/db_watchdog.sh"
MARK="# mtcl-watchdog:$RUN_DIR"                     # unique per run-dir (sh treats it as a comment)
LINE="*/10 * * * * $WD_SCRIPT $RUN_DIR >/dev/null 2>&1 $MARK"

# Operator = the invoking user, or the sudo caller when run from a sudo deploy.
TARGET_USER="${SUDO_USER:-$(id -un)}"
# Run crontab against TARGET_USER's table. Plain `crontab` for your own; `crontab -u`
# (root-only) when editing someone else's (deploy-as-root installing for the operator).
_ct() {
  if [ "$(id -un)" = "$TARGET_USER" ]; then crontab "$@"; else crontab -u "$TARGET_USER" "$@"; fi
}

if ! command -v crontab >/dev/null 2>&1; then
  echo "! crontab not available — cannot manage the watchdog schedule here." >&2
  exit 0                                            # non-fatal for deploy
fi

# current crontab minus any line for THIS run-dir
current="$(_ct -l 2>/dev/null | grep -vF "$MARK" || true)"

case "$ACTION" in
  install)
    chmod +x "$WD_SCRIPT" "$SELF_DIR/recover_db.sh" 2>/dev/null || true
    printf '%s\n%s\n' "$current" "$LINE" | grep -v '^[[:space:]]*$' | _ct -
    echo "✓ watchdog cron installed (*/10) for $RUN_DIR   [crontab: $TARGET_USER]"
    ;;
  remove|uninstall)
    printf '%s\n' "$current" | grep -v '^[[:space:]]*$' | _ct - || _ct -r 2>/dev/null || true
    echo "✓ watchdog cron removed for $RUN_DIR   [crontab: $TARGET_USER]"
    ;;
  status)
    _ct -l 2>/dev/null | grep -F "$MARK" && echo "  (installed for $TARGET_USER)" \
      || echo "not installed for $RUN_DIR   [crontab: $TARGET_USER]"
    ;;
  *)
    echo "usage: $0 install|remove|status [RUN_DIR]"; exit 1 ;;
esac
