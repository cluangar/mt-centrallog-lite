#!/bin/bash
# host_facts.sh — keep a run dir pointed at the LAN this box is ACTUALLY on.
#
# Why this exists: the Lite / Claw8ai box is portable. Its address is whatever
# network it is plugged into, and the operator's decision (2026-11-23) is that a
# move must NOT require hand-editing .env. Four keys describe the physical LAN
# (MNDP_PARENT_IFACE / MNDP_SUBNET / MNDP_GATEWAY / MNDP_IP_RANGE) and two more
# name "this server" (TLS_SAN for the HTTPS leaf, BACKEND_FETCH_URL for the
# address a router fetches from). Left stale after a move they fail in ways no
# API or topology gate can see: the leaf names an address nobody types, the
# device-side fetch points at a host that no longer exists, and the ipvlan child
# sits on a subnet nothing routes on.
#
# Two outputs, in order:
#   1. <run-dir>/host_facts/host_ips.txt  — the host's current IPv4s, the
#      default-route LAN address FIRST. Mounted read-only into nginx, the backend
#      and the poller (/etc/mtc-host-facts/host_ips.txt), where it is the tier
#      that needs no hand-edited value at all: the nginx entrypoint unions it
#      into the leaf SAN, and the backend checks its own BACKEND_FETCH_URL
#      against it instead of trusting the file blindly.
#   2. .env repair — ONLY with --apply (the Lite scripts). A key is rewritten
#      only when it disagrees with the measured LAN; a value that already matches
#      stays byte-identical, and the previous file is copied BESIDE it at mode 600
#      first (never to /tmp — that copy holds every secret the .env does).
#      --facts-only (the Full scripts) writes (1) and touches nothing else: the
#      production box is not portable and its .env is not a script's to edit.
#
# MNDP_IP_RANGE is deliberately conservative. install.sh's own suggestion is
# .192/28, but on 192.168.1.0/24 that block's lowest address is a LIVE host
# (00:48:54:20:44:18, also owning .118) — a collision that ran healthy until a
# census found it. So: a range already inside the measured subnet is NEVER
# touched (it is a census pick, not drift); a range on a stale subnet is re-based
# to the SAME last-octet block when that block is 16-aligned and in range, and
# only otherwise falls back to .192/28.
#
# Usage (from anywhere):
#   ./host_facts.sh [run-dir] [--apply | --facts-only] [--dry-run]
# Exit 0 for a normal run — a detection failure reports and writes NOTHING
# rather than guessing a subnet; 2 on a bad argument.

set -uo pipefail

RUN_DIR="$(pwd)"
MODE="facts"        # facts | apply
DRY=0
FACTS_ONLY_GIVEN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) MODE="apply" ;;
    --facts-only) MODE="facts"; FACTS_ONLY_GIVEN=1 ;;
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '1,45p' "$0"; exit 0 ;;
    --*) echo "host_facts: unknown option $1" >&2; exit 2 ;;
    *)  RUN_DIR="$1" ;;
  esac
  shift
done

# `--dry-run` previews what `--apply` WOULD write and changes nothing. Pair it with
# `--facts-only` to preview the facts file only.
if [ "$DRY" = 1 ] && [ "$FACTS_ONLY_GIVEN" = 0 ]; then MODE="apply"; fi

[ -d "$RUN_DIR" ] || { echo "host_facts: run dir $RUN_DIR not found" >&2; exit 2; }

FACTS_DIR="$RUN_DIR/host_facts"
FACTS_FILE="$FACTS_DIR/host_ips.txt"
ENV_FILE="$RUN_DIR/.env"

# ── Detect the LAN the box is on right now ──────────────────────────────────
DEF_IFACE=$(ip route show default 2>/dev/null | awk '/default/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
DEF_GW=$(ip route show default 2>/dev/null | awk '/default/{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')
LAN_IFACE="$DEF_IFACE"

# A default route over a tunnel is not a broadcast domain, so it cannot be an
# ipvlan parent. Fall back to a real LAN NIC.
if echo "${DEF_IFACE:-}" | grep -qE '^(ppp|tun|tap|wg|ipsec|l2tp)'; then
  LAN_IFACE=""
  while read -r cand cidr; do
    case "$cand" in
      lo|ppp*|tun*|tap*|wg*|ipsec*|l2tp*|docker*|br-*|veth*|virbr*|br*) continue ;;
    esac
    case "$cidr" in
      10.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|192.168.*) LAN_IFACE="$cand"; break ;;
    esac
  done < <(ip -4 -o addr show 2>/dev/null | awk '{print $2, $4}')
  if [ -n "$LAN_IFACE" ]; then
    DEF_GW=$(ip route show dev "$LAN_IFACE" 2>/dev/null | awk '/via/{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')
  fi
fi

LAN_CIDR=""
[ -n "$LAN_IFACE" ] && LAN_CIDR=$(ip -4 -o addr show "$LAN_IFACE" 2>/dev/null | awk '/inet /{print $4; exit}')
LAN_IP="${LAN_CIDR%/*}"

network_from_cidr() {
  local cidr="$1" ip="${1%/*}" prefix="${1#*/}" a b c d
  IFS='.' read -r a b c d <<< "$ip"
  case "$prefix" in
    24) echo "${a}.${b}.${c}.0/24" ;;
    16) echo "${a}.${b}.0.0/16" ;;
    8)  echo "${a}.0.0.0/${prefix}" ;;
    *)  echo "${a}.${b}.${c}.0/${prefix}" ;;
  esac
}

LAN_SUBNET=""
[ -n "$LAN_CIDR" ] && LAN_SUBNET=$(network_from_cidr "$LAN_CIDR")

# Every host IPv4, the LAN address FIRST. Container-side interfaces are excluded:
# a docker bridge address is real, but it is not an address a device can reach us
# at, and putting it in a SAN is how a leaf ends up naming an interface nobody
# uses. Loopback and link-local (169.254.x, what a host states about a network it
# has no route to) are excluded for the same reason.
ALL_IPS=$(ip -4 -o addr show 2>/dev/null | awk '
  $2 ~ /^(lo|docker[0-9]*|br-.*|veth.*|virbr.*|br.*)$/ { next }
  { split($4, a, "/"); if (a[1] != "" && a[1] !~ /^127\./ && a[1] !~ /^169\.254\./ && a[1] != "0.0.0.0") print a[1] }' \
  | awk -v first="$LAN_IP" 'BEGIN { if (first != "") print first } { if ($0 != first) print }')

if [ -z "$LAN_IP" ] || [ -z "$LAN_SUBNET" ]; then
  # No opinion beats a guess: a wrong subnet written into .env strands the
  # macvlan child on an L2 nothing routes on — the exact failure this exists to
  # prevent.
  echo "host_facts: could not detect a LAN interface/address — writing nothing."
  echo "          iface=${LAN_IFACE:-<none>} cidr=${LAN_CIDR:-<none>} default=${DEF_IFACE:-<none>}"
  exit 0
fi

# ── 1. The facts file (atomic; the containers read it, never edit it) ───────
mkdir -p "$FACTS_DIR" 2>/dev/null || true
TMP="$FACTS_DIR/.host_ips.txt.tmp"
{
  echo "# host_facts.sh — the IPv4s of THIS host, LAN address first."
  echo "# iface=$LAN_IFACE subnet=$LAN_SUBNET gateway=${DEF_GW:-none}"
  echo "# written: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "$ALL_IPS"
} > "$TMP" 2>/dev/null || { echo "host_facts: cannot write $TMP (directory not writable?)" >&2; exit 0; }

if [ "$DRY" = 1 ]; then
  rm -f "$TMP"
else
  mv -f "$TMP" "$FACTS_FILE"
fi

echo "host_facts: iface=$LAN_IFACE host=$LAN_IP subnet=$LAN_SUBNET gateway=${DEF_GW:-none}"
echo "host_facts: addresses = $(echo "$ALL_IPS" | tr '\n' ' ')"

# ── 2. .env repair (Lite only) ──────────────────────────────────────────────
if [ "$MODE" != "apply" ]; then
  echo "host_facts: .env not touched (--facts-only mode)."
  exit 0
fi
if [ ! -f "$ENV_FILE" ]; then
  echo "host_facts: no $ENV_FILE — facts written, .env untouched."
  exit 0
fi

env_get() { grep -E "^\s*$1=" "$ENV_FILE" | tail -1 | sed -E "s/^[^=]*=//" | sed -E 's/[[:space:]]*#.*$//'; }

CHANGED=0
BAK=""
BAK_TAKEN=0
note() { echo "host_facts: $*"; }

back_up_first() {
  # BEFORE the first edit, so the copy is the previous state — a backup written
  # after the repair would only prove the repair is idempotent.
  [ "$BAK_TAKEN" = 1 ] && return
  BAK_TAKEN=1
  # The before-image is a whole copy of the run dir's .env — device passwords, API
  # keys, the Telegram token — so it belongs BESIDE that file at mode 600. The old
  # path wrote it to /tmp at mode 644, which is a world-readable credential file on
  # every move (BACKLOG #155, measured 2026-11-25: 17,569 B, byte-identical to .env).
  BAK="$(dirname "$ENV_FILE")/.env.bak-$(date +%Y%m%d%H%M%S)-hostfacts"
  if cp -p "$ENV_FILE" "$BAK" 2>/dev/null && chmod 600 "$BAK" 2>/dev/null; then
    note "previous .env kept at $BAK (mode 600, beside the run dir)"
    return
  fi
  # Run dir not writable — fall back, but never world-readable, and say what to do.
  BAK="/tmp/.env.bak-$(date +%Y%m%d%H%M%S)-hostfacts"
  if cp -p "$ENV_FILE" "$BAK" 2>/dev/null && chmod 600 "$BAK" 2>/dev/null; then
    note "previous .env kept at $BAK (mode 600) — the run dir was not writable; shred it once the move is verified"
  else
    note "could not back up $ENV_FILE — continuing, but there is no before-image"
  fi
}

set_env() {
  local key="$1" val="$2" esc
  esc=$(printf '%s\n' "$val" | sed -e 's/[|&]/\\&/g')
  if [ "$DRY" = 1 ]; then note "would set $key=$val (was '$(env_get "$key")')"; CHANGED=1; return; fi
  back_up_first
  if grep -qE "^${key}=" "$ENV_FILE"; then
    sed -i "s|^${key}=.*|${key}=${esc}|" "$ENV_FILE"
  elif grep -qE "^#${key}=" "$ENV_FILE"; then
    sed -i "s|^#${key}=.*|${key}=${esc}|" "$ENV_FILE"
  else
    echo "${key}=${esc}" >> "$ENV_FILE"
  fi
  note "set $key=$val"
  CHANGED=1
}

# BACKEND_FETCH_URL: only a value naming an address this host does NOT have is
# wrong. An EMPTY value is the deliberate "no device-side fetch" state and stays
# empty — the backend derives on its own when a transfer needs one.
CUR_FETCH=$(env_get BACKEND_FETCH_URL)
if [ -n "$CUR_FETCH" ]; then
  CUR_FETCH_HOST=$(printf '%s' "$CUR_FETCH" | sed -E 's|^[a-zA-Z]+://||; s|[:/].*$||')
  if [ -n "$CUR_FETCH_HOST" ] && ! echo "$ALL_IPS" | grep -qx "$CUR_FETCH_HOST"; then
    PORT=$(printf '%s' "$CUR_FETCH" | sed -nE 's|^[^/]*://[^/:]*:([0-9]+).*|\1|p')
    set_env BACKEND_FETCH_URL "http://${LAN_IP}:${PORT:-80}"
  fi
fi

# TLS_SAN: add any host address the SAN does not already name. Existing entries
# are kept — an extra IP in a SAN is harmless, dropping one is not.
CUR_SAN=$(env_get TLS_SAN)
if [ -n "$CUR_SAN" ]; then
  NEW_SAN="$CUR_SAN"
  for ip in $ALL_IPS; do
    case ",$NEW_SAN," in *",IP:$ip,"*) continue ;; esac
    NEW_SAN="$NEW_SAN,IP:$ip"
  done
  [ "$NEW_SAN" != "$CUR_SAN" ] && set_env TLS_SAN "$NEW_SAN"
fi

# MNDP_* describe the physical L2: a disagreement IS the move.
CUR_IFACE=$(env_get MNDP_PARENT_IFACE)
[ -n "$CUR_IFACE" ] && [ "$CUR_IFACE" != "$LAN_IFACE" ] && set_env MNDP_PARENT_IFACE "$LAN_IFACE"
CUR_SUBNET=$(env_get MNDP_SUBNET)
[ -n "$CUR_SUBNET" ] && [ "$CUR_SUBNET" != "$LAN_SUBNET" ] && set_env MNDP_SUBNET "$LAN_SUBNET"
if [ -n "$DEF_GW" ]; then
  CUR_GW=$(env_get MNDP_GATEWAY)
  [ -n "$CUR_GW" ] && [ "$CUR_GW" != "$DEF_GW" ] && set_env MNDP_GATEWAY "$DEF_GW"
fi

# MNDP_IP_RANGE — the conservative one. Inside the measured subnet it is a census
# pick and is never rewritten; a stale one keeps its own block, not install.sh's
# .192 suggestion.
CUR_RANGE=$(env_get MNDP_IP_RANGE)
if [ -n "$CUR_RANGE" ]; then
  R_BASE="${CUR_RANGE%/*}"; R_LAST="${R_BASE##*.}"; R_NET="${R_BASE%.*}"
  L_NET="${LAN_SUBNET%/*}"; L_NET="${L_NET%.*}"
  if [ -n "$R_NET" ] && [ "$R_NET" != "$L_NET" ]; then
    NEW_RANGE="${L_NET}.192/28"
    if [[ "$R_LAST" =~ ^[0-9]+$ ]] && [ $((R_LAST % 16)) -eq 0 ] && [ "$R_LAST" -le 240 ]; then
      NEW_RANGE="${L_NET}.${R_LAST}/28"
    fi
    [ "$NEW_RANGE" != "$CUR_RANGE" ] && set_env MNDP_IP_RANGE "$NEW_RANGE"
  fi
fi

if [ "$CHANGED" = 0 ]; then
  echo "host_facts: .env already matches this LAN — nothing changed."
elif [ "$DRY" = 1 ]; then
  echo "host_facts: --dry-run, .env unchanged."
fi
exit 0
