#!/bin/bash
# update-mndp.sh — Detect LAN settings and update MNDP variables in .env
# Run from the RUN dir (~/mt-centrallog-lite-docker), where .env lives:
#   ./update-mndp.sh

set -euo pipefail

ENV_FILE="$(cd "$(dirname "$0")" && pwd)/.env"

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'

echo -e "${CYAN}=== MNDP + backup network configuration updater (Lite) ===${NC}"
echo ""

# ── Check .env exists ────────────────────────────────────────────────────────

if [ ! -f "$ENV_FILE" ]; then
  echo -e "${RED}Error: .env not found at $ENV_FILE${NC}"
  echo "Run from the run dir (~/mt-centrallog-lite-docker) after ./deploy.sh."
  exit 1
fi

# ── Show current values ──────────────────────────────────────────────────────

echo -e "${YELLOW}Current .env MNDP settings:${NC}"
grep -E "^MNDP_" "$ENV_FILE" || echo "  (none set)"
echo ""
echo -e "${YELLOW}Current .env BACKEND_FETCH_URL:${NC}"
grep -E "^BACKEND_FETCH_URL=" "$ENV_FILE" || echo "  (not set)"
echo ""

# ── Auto-detect network settings ────────────────────────────────────────────

detect_iface() {
  ip route show default 2>/dev/null | awk '/default/{print $5}' | head -1
}

detect_ip_prefix() {
  local iface="$1"
  ip addr show "$iface" 2>/dev/null | awk '/inet /{print $2}' | head -1
}

detect_gateway() {
  ip route show default 2>/dev/null | awk '/default/{print $3}' | head -1
}

network_from_cidr() {
  local cidr="$1"
  local ip="${cidr%/*}"
  local prefix="${cidr#*/}"
  IFS='.' read -r a b c d <<< "$ip"
  case "$prefix" in
    24) echo "${a}.${b}.${c}.0/${prefix}" ;;
    16) echo "${a}.${b}.0.0/${prefix}" ;;
    8)  echo "${a}.0.0.0/${prefix}" ;;
    *)  echo "${a}.${b}.${c}.0/${prefix}" ;;
  esac
}

suggested_range() {
  local subnet="$1"
  local base="${subnet%.*}"
  base="${base%/*}"
  echo "${base}.192/28"
}

AUTO_IFACE=$(detect_iface || true)
AUTO_CIDR=$(detect_ip_prefix "$AUTO_IFACE" 2>/dev/null || true)
AUTO_GATEWAY=$(detect_gateway || true)
AUTO_SUBNET=""
AUTO_RANGE=""
AUTO_HOST_IP=""
AUTO_FETCH_URL=""

if [ -n "$AUTO_CIDR" ]; then
  AUTO_SUBNET=$(network_from_cidr "$AUTO_CIDR")
  AUTO_RANGE=$(suggested_range "$AUTO_SUBNET")
  AUTO_HOST_IP="${AUTO_CIDR%/*}"
  AUTO_FETCH_URL="http://${AUTO_HOST_IP}:80"
fi

echo -e "${YELLOW}Auto-detected:${NC}"
echo "  Interface : ${AUTO_IFACE:-not found}"
echo "  Host IP   : ${AUTO_CIDR:-not found}"
echo "  Subnet    : ${AUTO_SUBNET:-not found}"
echo "  Gateway   : ${AUTO_GATEWAY:-not found}"
echo "  Suggested IP range (outside DHCP): ${AUTO_RANGE:-not found}"
echo "  Suggested BACKEND_FETCH_URL       : ${AUTO_FETCH_URL:-not found}"
echo ""
echo -e "${YELLOW}DHCP pool tip:${NC} set MNDP_IP_RANGE to a block your DHCP server will NOT assign."
echo "  Default suggestion .192/28 covers .192–.207 — verify this is outside your DHCP pool."
echo ""
echo -e "${YELLOW}BACKEND_FETCH_URL tip:${NC} use the IP MikroTik devices see this server at (LAN IP + nginx port 80)."
echo "  Leave blank to disable the /tool/fetch push fallback for backups."
echo ""

# ── Prompt for each value ────────────────────────────────────────────────────

prompt() {
  local label="$1" default="$2" var
  read -rp "  ${label} [${default}]: " var
  echo "${var:-$default}"
}

echo -e "${CYAN}Press Enter to accept the detected value, or type a new one:${NC}"
echo ""

NEW_IFACE=$(prompt      "MNDP_PARENT_IFACE  " "${AUTO_IFACE:-wlo1}")
NEW_SUBNET=$(prompt     "MNDP_SUBNET        " "${AUTO_SUBNET:-192.168.10.0/24}")
NEW_GATEWAY=$(prompt    "MNDP_GATEWAY       " "${AUTO_GATEWAY:-192.168.10.1}")
NEW_RANGE=$(prompt      "MNDP_IP_RANGE      " "${AUTO_RANGE:-192.168.10.192/28}")
NEW_FETCH_URL=$(prompt  "BACKEND_FETCH_URL  " "${AUTO_FETCH_URL:-}")

echo ""
echo -e "${YELLOW}Will write to .env:${NC}"
echo "  MNDP_PARENT_IFACE=$NEW_IFACE"
echo "  MNDP_SUBNET=$NEW_SUBNET"
echo "  MNDP_GATEWAY=$NEW_GATEWAY"
echo "  MNDP_IP_RANGE=$NEW_RANGE"
echo "  BACKEND_FETCH_URL=$NEW_FETCH_URL"
echo ""
read -rp "Apply? [y/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "Aborted — .env unchanged."
  exit 0
fi

# ── Update .env ──────────────────────────────────────────────────────────────

set_env() {
  local key="$1" val="$2"
  if grep -qE "^${key}=" "$ENV_FILE"; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
  elif grep -qE "^#${key}=" "$ENV_FILE"; then
    sed -i "s|^#${key}=.*|${key}=${val}|" "$ENV_FILE"
  else
    echo "${key}=${val}" >> "$ENV_FILE"
  fi
}

set_env "MNDP_PARENT_IFACE"  "$NEW_IFACE"
set_env "MNDP_SUBNET"        "$NEW_SUBNET"
set_env "MNDP_GATEWAY"       "$NEW_GATEWAY"
set_env "MNDP_IP_RANGE"      "$NEW_RANGE"
set_env "BACKEND_FETCH_URL"  "$NEW_FETCH_URL"

echo -e "${GREEN}✓ .env updated.${NC}"
echo ""
echo -e "${YELLOW}Next step — recreate the macvlan_lan Docker network:${NC}"
echo "  ./start.sh restart          # or: docker compose down && docker compose up -d --no-build"
echo ""
echo -e "${YELLOW}Verify backend got the right IP after restart:${NC}"
echo "  docker exec mt-centrallog-lite-backend-1 python3 -c \""
echo "    import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)"
echo "    s.connect(('8.8.8.8',1)); print('container LAN IP:', s.getsockname()[0]); s.close()\""
