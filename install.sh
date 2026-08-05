#!/bin/bash
# mt-centrallog Lite — one-line installer.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/cluangar/mt-centrallog-lite/main/install.sh | bash
#
# What it does:
#   1. Preflight: Docker + Compose v2, ports 80/443 free, ip command available
#   2. Create install dir (default $HOME/mt-centrallog-lite)
#   3. Fetch: docker-compose.yml, .env.example, update.sh, update-mndp.sh
#   4. Generate a strong SECRET_KEY and a BACKEND_API_KEY
#   5. Auto-detect LAN interface / subnet / gateway; write MNDP_* into .env
#   6. docker compose pull && docker compose up -d
#   7. Print the URL
#
# Re-run safe: if the install dir exists and has a .env, the script exits
# without touching anything and tells you to run ./update.sh instead.
set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────
REPO="cluangar/mt-centrallog-lite"
BRANCH="${MT_LITE_BRANCH:-main}"
BASE_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
INSTALL_DIR="${MT_LITE_DIR:-$HOME/mt-centrallog-lite}"

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'

say()  { echo -e "${CYAN}==>${NC} $*"; }
warn() { echo -e "${YELLOW}!${NC}  $*"; }
die()  { echo -e "${RED}✗${NC}  $*" >&2; exit 1; }
ok()   { echo -e "${GREEN}✓${NC}  $*"; }

# ── Preflight ─────────────────────────────────────────────────────────────
say "mt-centrallog Lite installer"
echo ""

command -v docker >/dev/null 2>&1 || die "Docker is not installed. See https://docs.docker.com/engine/install/"
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is not installed (need 'docker compose', not the legacy 'docker-compose')."
command -v curl >/dev/null 2>&1 || die "curl is required."
command -v ip >/dev/null 2>&1 || die "The 'ip' command is required (iproute2)."

# Root/docker-group check
if ! docker ps >/dev/null 2>&1; then
  die "Cannot talk to the Docker daemon. Either run as root/sudo, or add yourself to the 'docker' group and re-login."
fi

# Port availability (only if something is currently listening)
for port in 80 443; do
  if ss -ltn "sport = :$port" 2>/dev/null | grep -q LISTEN; then
    warn "TCP port $port is already in use. If a Lite install is not already running, edit .env after this script finishes to change WEB_HTTP_PORT / WEB_HTTPS_PORT."
  fi
done

# ── Already installed? ────────────────────────────────────────────────────
if [ -d "$INSTALL_DIR" ] && [ -f "$INSTALL_DIR/.env" ]; then
  warn "Existing install found at $INSTALL_DIR"
  echo "    To upgrade to the latest image, run:"
  echo "        cd $INSTALL_DIR && ./update.sh"
  echo "    To reinstall from scratch, remove that directory first (KEEP sqlite_data/ if you want to preserve data)."
  exit 0
fi

# ── Auto-detect network ───────────────────────────────────────────────────
say "Auto-detecting LAN settings…"

DETECT_IFACE=$(ip route show default 2>/dev/null | awk '/default/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}') || true
DETECT_GATEWAY=$(ip route show default 2>/dev/null | awk '/default/{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}') || true

# Default route may point at a VPN/tunnel (ppp0, tun0, wg0…) instead of the
# real LAN NIC — those aren't broadcast-domain interfaces and can't be an
# ipvlan/macvlan parent. Fall back to scanning for a real LAN NIC instead.
if echo "$DETECT_IFACE" | grep -qE '^(ppp|tun|tap|wg)'; then
  DETECT_IFACE=""
  DETECT_GATEWAY=""
  while read -r cand_iface cand_cidr; do
    case "$cand_iface" in
      lo|ppp*|tun*|tap*|wg*|docker*|veth*|br-*|virbr*) continue ;;
    esac
    case "$cand_cidr" in
      10.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|192.168.*)
        DETECT_IFACE="$cand_iface"
        break
        ;;
    esac
  done < <(ip -4 -o addr show 2>/dev/null | awk '{print $2, $4}')
  if [ -n "$DETECT_IFACE" ]; then
    DETECT_GATEWAY=$(ip route show dev "$DETECT_IFACE" 2>/dev/null | awk '/via/{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}') || true
  fi
fi

DETECT_CIDR=""
if [ -n "$DETECT_IFACE" ]; then
  DETECT_CIDR=$(ip -4 addr show "$DETECT_IFACE" 2>/dev/null | awk '/inet /{print $2; exit}') || true
fi

network_from_cidr() {
  local cidr="$1"
  local ip="${cidr%/*}"
  local prefix="${cidr#*/}"
  IFS='.' read -r a b c d <<< "$ip"
  case "$prefix" in
    24) echo "${a}.${b}.${c}.0/24" ;;
    16) echo "${a}.${b}.0.0/16" ;;
    *)  echo "${a}.${b}.${c}.0/${prefix}" ;;
  esac
}

DETECT_SUBNET=""
DETECT_RANGE=""
if [ -n "$DETECT_CIDR" ]; then
  DETECT_SUBNET=$(network_from_cidr "$DETECT_CIDR")
  base="${DETECT_SUBNET%.*}"
  DETECT_RANGE="${base}.192/28"
fi

echo "    Interface : ${DETECT_IFACE:-<not found>}"
echo "    Host IP   : ${DETECT_CIDR:-<not found>}"
echo "    Subnet    : ${DETECT_SUBNET:-<not found>}"
echo "    Gateway   : ${DETECT_GATEWAY:-<not found>}"
echo "    MNDP range: ${DETECT_RANGE:-<not found>}"
echo ""

if [ -z "$DETECT_IFACE" ] || [ -z "$DETECT_CIDR" ]; then
  warn "Could not auto-detect the LAN. Install will proceed with placeholders — you MUST run ./update-mndp.sh after install to fix MNDP_* before MikroTik discovery works."
fi

# ── Fetch artifacts ───────────────────────────────────────────────────────
say "Fetching artifacts from ${BASE_URL}"

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

fetch() {
  local file="$1"
  curl -fsSL "${BASE_URL}/${file}" -o "$file" || die "Could not fetch $file"
}

fetch docker-compose.yml
fetch .env.example
fetch update.sh
fetch update-mndp.sh
fetch db_watchdog.sh
fetch recover_db.sh
fetch watchdog-cron.sh
chmod +x update.sh update-mndp.sh db_watchdog.sh recover_db.sh watchdog-cron.sh

# Data dirs
mkdir -p sqlite_data backup_data capture_data

# ── Seed .env ─────────────────────────────────────────────────────────────
say "Generating secrets and writing .env"

# Prefer python3 for tokens; fall back to openssl.
gen_secret() {
  local bytes="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import secrets; print(secrets.token_urlsafe(${bytes}))"
  elif command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 "$bytes" | tr -d '\n=+/' | cut -c1-$((bytes * 4 / 3))
  else
    die "Neither python3 nor openssl is available — cannot generate secrets."
  fi
}

SECRET_KEY=$(gen_secret 48)
BACKEND_API_KEY=$(gen_secret 32)

cp .env.example .env

sed_set() {
  local key="$1" val="$2"
  # Escape | in val for sed
  local esc
  esc=$(printf '%s\n' "$val" | sed -e 's/[|&]/\\&/g')
  if grep -qE "^${key}=" .env; then
    sed -i "s|^${key}=.*|${key}=${esc}|" .env
  else
    echo "${key}=${esc}" >> .env
  fi
}

sed_set SECRET_KEY       "$SECRET_KEY"
sed_set BACKEND_API_KEY  "$BACKEND_API_KEY"
[ -n "$DETECT_IFACE" ]  && sed_set MNDP_PARENT_IFACE "$DETECT_IFACE"
[ -n "$DETECT_SUBNET" ] && sed_set MNDP_SUBNET       "$DETECT_SUBNET"
[ -n "$DETECT_GATEWAY" ]&& sed_set MNDP_GATEWAY      "$DETECT_GATEWAY"
[ -n "$DETECT_RANGE" ]  && sed_set MNDP_IP_RANGE     "$DETECT_RANGE"
[ -n "$DETECT_CIDR" ]   && sed_set BACKEND_FETCH_URL "http://${DETECT_CIDR%/*}:80"

ok ".env written to $INSTALL_DIR/.env"

# ── Pull + start ──────────────────────────────────────────────────────────
say "Pulling images (this may take a few minutes on first run)…"
docker compose pull

say "Starting Lite stack…"
docker compose up -d

# ── Install the DB watchdog cron (auto-detect + auto-recover DB corruption) ─
if [ -x "$INSTALL_DIR/watchdog-cron.sh" ]; then
  "$INSTALL_DIR/watchdog-cron.sh" install "$INSTALL_DIR" \
    && ok "DB watchdog scheduled (every 10 min). Toggle via DB_WATCHDOG_ENABLED / DB_WATCHDOG_AUTORECOVER in .env." \
    || warn "Could not install the watchdog cron (no crontab?). The stack still runs; recovery is manual."
fi

# ── Post-install summary ──────────────────────────────────────────────────
echo ""
ok "mt-centrallog Lite is installed."
echo ""
echo "    Install dir : $INSTALL_DIR"
echo "    URL         : http://${DETECT_CIDR%/*}/    (https on port 443, self-signed)"
echo "    Login       : admin / admin1234    ← CHANGE THIS IMMEDIATELY"
echo ""
echo "    Update      : cd $INSTALL_DIR && ./update.sh"
echo "    Change LAN  : cd $INSTALL_DIR && ./update-mndp.sh"
echo "    Logs        : cd $INSTALL_DIR && docker compose logs -f backend poller"
echo "    Stop        : cd $INSTALL_DIR && docker compose down"
echo ""
if [ -z "$DETECT_IFACE" ] || [ -z "$DETECT_CIDR" ]; then
  warn "LAN auto-detect failed. Run ./update-mndp.sh now — MikroTik discovery will not work until you do."
fi
