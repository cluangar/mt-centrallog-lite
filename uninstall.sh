#!/bin/bash
# uninstall.sh — remove mt-centrallog Lite from this machine.
#
# Usage:
#   ./uninstall.sh            # stop stack + delete everything (incl. data)
#   ./uninstall.sh --keep-data  # stop stack + delete app files, keep sqlite_data/
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; NC='\033[0m'
say()  { echo -e "${CYAN}==>${NC} $*"; }
ok()   { echo -e "${GREEN}✓${NC}  $*"; }
warn() { echo -e "${YELLOW}!${NC}  $*"; }
die()  { echo -e "${RED}✗${NC}  $*" >&2; exit 1; }

KEEP_DATA=false
for arg in "$@"; do
  case "$arg" in
    --keep-data) KEEP_DATA=true ;;
    -h|--help)
      echo "Usage: $0 [--keep-data]"
      echo "  --keep-data   preserve sqlite_data/, backup_data/, capture_data/ and .env"
      exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

# Resolve real home even under sudo
REAL_HOME=$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)
INSTALL_DIR="${REAL_HOME}/mt-centrallog-lite"

[ -d "$INSTALL_DIR" ] || die "mt-centrallog Lite not found at ${INSTALL_DIR}"

echo ""
warn "This will STOP mt-centrallog Lite and remove ${INSTALL_DIR}."
if $KEEP_DATA; then
  warn "Data directories (sqlite_data/, backup_data/, capture_data/) will be KEPT."
else
  warn "ALL DATA including sqlite_data/ will be DELETED. Back up first if needed."
fi
echo ""
read -r -p "Continue? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
echo ""

# --- Stop the stack ---
say "Stopping stack"
cd "$INSTALL_DIR"
docker compose down --remove-orphans 2>/dev/null || \
  docker compose -p mt-centrallog-lite down --remove-orphans 2>/dev/null || true
cd - >/dev/null

# --- Remove files ---
if $KEEP_DATA; then
  say "Removing app files (keeping data directories)"
  rm -f  "${INSTALL_DIR}/docker-compose.yml" \
         "${INSTALL_DIR}/update.sh" \
         "${INSTALL_DIR}/update-mndp.sh" \
         "${INSTALL_DIR}/uninstall.sh"
  ok "App files removed. Data kept at ${INSTALL_DIR}/"
else
  say "Removing ${INSTALL_DIR}"
  rm -rf "${INSTALL_DIR:?}"
  ok "Removed ${INSTALL_DIR}"
fi

# --- Optionally remove pulled images ---
echo ""
read -r -p "Remove pulled Docker images from this machine? [y/N] " rmi_confirm
if [[ "$rmi_confirm" =~ ^[Yy]$ ]]; then
  say "Removing images"
  for svc in backend poller frontend nginx mndp-relay; do
    docker rmi -f "ghcr.io/cluangar/mt-centrallog-lite-${svc}:latest" 2>/dev/null || true
  done
  ok "Images removed"
fi

echo ""
ok "mt-centrallog Lite uninstalled."
