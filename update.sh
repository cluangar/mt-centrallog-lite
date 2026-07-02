#!/bin/bash
# update.sh — pull the latest Lite images and recreate the stack.
#
# Payoff of the two-directory split: this NEVER touches ./sqlite_data,
# ./backup_data, ./capture_data, or .env. Only the images get swapped.
#
# Usage (from the install dir):
#   ./update.sh                 # pull :latest and recreate
#   ./update.sh 1.5.290         # pin to a specific version (writes IMAGE_TAG into .env)
#   ./update.sh --refresh       # also refresh compose file / update-mndp.sh from GitHub
set -euo pipefail

cd "$(dirname "$0")"

REPO="cluangar/mt-centrallog-lite"
BRANCH="${MT_LITE_BRANCH:-main}"
BASE_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}"

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
say()  { echo -e "${CYAN}==>${NC} $*"; }
ok()   { echo -e "${GREEN}✓${NC}  $*"; }
warn() { echo -e "${YELLOW}!${NC}  $*"; }
die()  { echo -e "${RED}✗${NC}  $*" >&2; exit 1; }

[ -f .env ] || die ".env not found. Run this from the install dir (default: ~/mt-centrallog-lite)."

REFRESH=false
VERSION=""
for arg in "$@"; do
  case "$arg" in
    --refresh) REFRESH=true ;;
    -*) die "Unknown flag: $arg" ;;
    *) VERSION="$arg" ;;
  esac
done

# ── Pin an explicit version (writes IMAGE_TAG to .env) ────────────────────
if [ -n "$VERSION" ]; then
  if ! echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    die "Version '$VERSION' does not look like X.Y.Z."
  fi
  if grep -qE '^IMAGE_TAG=' .env; then
    sed -i "s|^IMAGE_TAG=.*|IMAGE_TAG=${VERSION}|" .env
  else
    echo "IMAGE_TAG=${VERSION}" >> .env
  fi
  say "Pinned IMAGE_TAG=${VERSION} in .env"
fi

# ── Optionally refresh the compose file + helper scripts ─────────────────
if $REFRESH; then
  say "Refreshing docker-compose.yml + update-mndp.sh from ${BASE_URL}"
  for file in docker-compose.yml update-mndp.sh; do
    curl -fsSL "${BASE_URL}/${file}" -o "${file}.new" || die "Fetch failed: $file"
    mv "${file}.new" "$file"
  done
  chmod +x update-mndp.sh
fi

# ── Pull + recreate ──────────────────────────────────────────────────────
say "Pulling images…"
docker compose pull

say "Recreating containers…"
docker compose up -d

ok "Update complete."
docker compose ps
