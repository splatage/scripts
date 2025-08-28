#!/usr/bin/env bash
# install-bungeef2b.sh — Install Fail2Ban filters/jails for FlameCord + NuVotifier
# Usage:
#   sudo ./install-bungeef2b.sh [-p LOG_PATH] [-b BACKEND] [-i IGNORE_IPS] [-A ACTION] [-l]
#   -p  Log path/glob   (default: /poolz/archive/home/minecraft/minecraft/bungee/game_files/logs/latest*.log)
#   -b  Backend         (default: polling)
#   -i  ignoreip list   (comma or space separated; e.g. "203.0.113.10,10.0.0.0/8,2001:db8::/32")
#   -A  action          (default: %(action_mw)s)
#   -l  enable latency rules (FlameCord "very high latency" bans)
# Example:
#   sudo ./install-bungeef2b.sh -i "10.0.0.0/8,2001:db8::/32" -l

set -euo pipefail

# -------- Defaults (can override with flags) --------
LOG_PATH="/poolz/archive/home/minecraft/minecraft/bungee/game_files/logs/latest*.log"
BACKEND="polling"
ACTION="%(action_mw)s"
IGNOREIP=""
ENABLE_LATENCY=0

PORT_PROXY="25565"
PORT_VOTIFIER="8192"

FIRE_BANTIME="86400"   # 24h
FIRE_FINDTIME="300"
FIRE_MAXRETRY="1"

NUVO_BANTIME="43200"   # 12h
NUVO_FINDTIME="600"
NUVO_MAXRETRY="2"

# -------- Args --------
while getopts ":p:b:i:A:l" opt; do
  case "$opt" in
    p) LOG_PATH="$OPTARG" ;;
    b) BACKEND="$OPTARG" ;;
    i) IGNOREIP="$OPTARG" ;;
    A) ACTION="$OPTARG" ;;
    l) ENABLE_LATENCY=1 ;;
    \?) echo "Unknown option: -$OPTARG" >&2; exit 2 ;;
  esac
done

# Normalize ignore list (allow comma or spaces)
IGNOREIP="$(echo "${IGNOREIP:-}" | sed 's/,/ /g' | xargs || true)"

# Require fail2ban present
if ! command -v fail2ban-client >/dev/null 2>&1; then
  echo "error: fail2ban is not installed. Install it first (apt/yum/pacman) and re-run." >&2
  exit 1
fi

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

FILTER_DIR="/etc/fail2ban/filter.d"
JAIL_DIR="/etc/fail2ban/jail.d"
BACKUP_DIR="/etc/fail2ban/.backup_$(date +%Y%m%d%H%M%S)"

echo "==> Installing Fail2Ban filters & jails for Bungee/FlameCord"
echo "    LOG_PATH : $LOG_PATH"
echo "    BACKEND  : $BACKEND"
echo "    ACTION   : $ACTION"
echo "    IGNOREIP : ${IGNOREIP:-<none>}"
echo "    Latency  : $([ $ENABLE_LATENCY -eq 1 ] && echo enabled || echo disabled)"

$SUDO mkdir -p "$FILTER_DIR" "$JAIL_DIR" "$BACKUP_DIR"

backup_if_exists() {
  local f="$1"
  if [ -f "$f" ]; then
    $SUDO cp -a "$f" "$BACKUP_DIR/"
    echo "    backed up: $f -> $BACKUP_DIR/"
  fi
}

backup_if_exists "$FILTER_DIR/flamecord.conf"
backup_if_exists "$FILTER_DIR/nuvotifier.conf"
backup_if_exists "$JAIL_DIR/bungeecord.local"

# -------- Write flamecord.conf --------
cat <<'EOF' | $SUDO tee "$FILTER_DIR/flamecord.conf" >/dev/null
[Definition]
# Timestamp like: [01:00:06]
datepattern = ^\[\d{2}:\d{2}:\d{2}\]

# VPN/Proxy detections
failregex = ^.*\[FlameCord\].*\[(?:/)?<HOST>(?::\d+)?\].*was\s+firewalled.*Using\s+VPN/Proxy\s+services.*$
            ^.*\[FlameCord\].*\[(?:/)?<HOST>:\d+\].*was\s+blocked\s+for\s+using\s+a\s+VPN/Proxy\s+service.*$
            ^.*\[FlameCord\].*\[(?:/)?<HOST>:\d+\].*is\s+firewalled\s+from\s+the\s+server\.\s*\(Using\s+VPN/Proxy\s+services\).*$

# QuietException variants
            ^.*\[FlameCord\].*\[(?:/)?<HOST>(?::\d+)?\]\s+was\s+firewalled\s+because\s+of\s+QuietException.*$
            ^.*\[FlameCord\].*\[(?:/)?<HOST>:\d+\]\s+is\s+firewalled\s+from\s+the\s+server\.\s*\(QuietException\).*$

# Optional: latency (can be enabled in jail via _LATENCY placeholder)
#            ^.*\[FlameCord\].*\[(?:/)?<HOST>(?::\d+)?\].*firewalled.*high.*latency.*$
#            ^.*\[FlameCord\].*\[(?:/)?<HOST>:\d+\].*has\s+a\s+very\s+high\s+latency\s+\(\d[\d,]*ms\).*$

ignoreregex =
EOF

# If latency is enabled, append the two latency patterns (activate them)
if [ "$ENABLE_LATENCY" -eq 1 ]; then
  cat <<'EOF' | $SUDO tee -a "$FILTER_DIR/flamecord.conf" >/dev/null

# Enabled latency patterns
failregex = %(failregex)s
            ^.*\[FlameCord\].*\[(?:/)?<HOST>(?::\d+)?\].*firewalled.*high.*latency.*$
            ^.*\[FlameCord\].*\[(?:/)?<HOST>:\d+\].*has\s+a\s+very\s+high\s+latency\s+\(\d[\d,]*ms\).*$

EOF
fi

# -------- Write nuvotifier.conf --------
cat <<'EOF' | $SUDO tee "$FILTER_DIR/nuvotifier.conf" >/dev/null
[Definition]
datepattern = ^\[\d{2}:\d{2}:\d{2}\]

# Main error line
failregex = ^.*\[NuVotifier\]:\s+Unable\s+to\s+process\s+vote\s+from\s+/<HOST>:\d+.*$

# Stack/transport variants that still include /IP:PORT
            ^.*(?:Could\s+not\s+decrypt|DecoderException|NativeIoException|QuietException).*\/<HOST>:\d+.*$

ignoreregex =
EOF

# -------- Write jail.d/bungeecord.local --------
# Compose ignoreip (inherit localhost always)
DEFAULT_IGNORE="127.0.0.1/8 ::1"
[ -n "$IGNOREIP" ] && DEFAULT_IGNORE="$DEFAULT_IGNORE $IGNOREIP"

tmpjail="$(mktemp)"
cat > "$tmpjail" <<EOF
[DEFAULT]
ignoreip = ${DEFAULT_IGNORE}

[flamecord]
enabled   = true
filter    = flamecord
logpath   = ${LOG_PATH}
backend   = ${BACKEND}
port      = ${PORT_PROXY}
maxretry  = ${FIRE_MAXRETRY}
findtime  = ${FIRE_FINDTIME}
bantime   = ${FIRE_BANTIME}
action    = ${ACTION}

[nuvotifier]
enabled   = true
filter    = nuvotifier
logpath   = ${LOG_PATH}
backend   = ${BACKEND}
port      = ${PORT_VOTIFIER}
maxretry  = ${NUVO_MAXRETRY}
findtime  = ${NUVO_FINDTIME}
bantime   = ${NUVO_BANTIME}
action    = ${ACTION}
EOF

$SUDO install -m 0644 "$tmpjail" "$JAIL_DIR/bungeecord.local"
rm -f "$tmpjail"

# -------- Quick regex sanity (non-fatal) --------
if command -v fail2ban-regex >/dev/null 2>&1; then
  echo "==> Quick regex checks (ok if empty when no matching lines yet):"
  $SUDO fail2ban-regex "${LOG_PATH%% *}" "$FILTER_DIR/flamecord.conf" || true
  $SUDO fail2ban-regex "${LOG_PATH%% *}" "$FILTER_DIR/nuvotifier.conf" || true
fi

# -------- Reload/Start fail2ban --------
if systemctl is-active --quiet fail2ban; then
  echo "==> Reloading fail2ban..."
  $SUDO fail2ban-client reload || $SUDO systemctl restart fail2ban
else
  echo "==> Starting fail2ban..."
  $SUDO systemctl start fail2ban || true
fi

echo "==> Current jail status:"
$SUDO fail2ban-client status flamecord || true
$SUDO fail2ban-client status nuvotifier || true

echo "==> Backups saved to: $BACKUP_DIR"
echo "Done."
