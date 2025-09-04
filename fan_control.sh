#!/bin/bash
# setup-fan-service.sh
# Installs /usr/local/sbin/fan_control.sh and a simple systemd unit with optional env overrides.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_PATH="/usr/local/sbin/fan_control.sh"
SERVICE_PATH="/etc/systemd/system/fan-control.service"
DEFAULTS_PATH="/etc/default/fan-control"

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Please run as root (sudo)." >&2
    exit 1
  fi
}

install_deps() {
  # Best-effort: install ipmitool and dmidecode if using a common package manager
  local pkgs=(ipmitool dmidecode)
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y "${pkgs[@]}"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "${pkgs[@]}"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "${pkgs[@]}"
  elif command -v zypper >/dev/null 2>&1; then
    zypper install -y "${pkgs[@]}"
  else
    echo "NOTE: Could not detect a supported package manager. Ensure these are installed: ${pkgs[*]}" >&2
  fi
}

write_script() {
  install -m 0755 /dev/stdin "${SCRIPT_PATH}" <<'FANEOF'
#!/bin/bash
# /usr/local/sbin/fan_control.sh
# Baseline-referenced fan control for IBM (step or linear hex) and Dell/Unisys (percent).
# - Takes ONE SDR snapshot per loop and keeps it IN MEMORY (no /tmp cache).
# - Uses the HOTTEST temperature reported by SDR to drive the fans.
# - Reissues current speed just BEFORE each read (keepalive) to prevent BMC ramp.
# - pct each cycle is based on TEMP vs BASELINE (not last delta), then clamped & slewed.
# - IBM_CODEMAP: "table" (classic) or "linear" (0x12..0xFF).

set -u -o pipefail
IFS=$'\n\t'
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ------------ single-instance lock ------------
LOCKFILE="/var/run/fan_control.lock"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
  echo "[$(date +'%F %T')] already running (lock $LOCKFILE). Exiting. PID=$$"
  exit 0
fi

# ------------ knobs ------------
INTERVAL=${INTERVAL:-30}        # seconds
BASELINE_C=${BASELINE_C:-45}    # target "quiet" °C
UP_GAIN=${UP_GAIN:-2}           # % per +1°C above baseline
DOWN_GAIN=${DOWN_GAIN:-1}       # % per -1°C below baseline
MIN_PCT=${MIN_PCT:-5}           # min %
MAX_PCT=${MAX_PCT:-60}          # max %
SLEW_PCT=${SLEW_PCT:-15}        # per-cycle max % change (0=off)
DEADBAND_C=${DEADBAND_C:-0}     # °C around baseline to keep MIN_PCT (0=off)

IBM_CODEMAP="${IBM_CODEMAP:-linear}"  # table|linear
IBM_BANK1="${IBM_BANK1:-0x01}"
IBM_BANK2="${IBM_BANK2:-0x02}"

# ------------ vendor detect ------------
lower(){ tr '[:upper:]' '[:lower:]'; }
detect_vendor() {
  local man prod base
  man="$(dmidecode -s system-manufacturer 2>/dev/null | lower || true)"
  prod="$(dmidecode -s system-product-name 2>/dev/null | lower || true)"
  base="$(dmidecode -s baseboard-manufacturer 2>/dev/null | lower || true)"
  local s="${man} ${base} ::: ${prod}"
  if echo "$s" | grep -Eq 'dell|emc|unisys'; then echo dell
  elif echo "$s" | grep -Eq 'ibm|lenovo'; then echo ibm
  else echo ibm; fi
}
VENDOR="$(detect_vendor)"
echo "[$(date +'%F %T')] start vendor=$VENDOR baseline=${BASELINE_C}C IBM_CODEMAP=${IBM_CODEMAP}"

# ------------ SDR snapshot (in memory) ------------
SDR=""
fetch_ipmi(){
  SDR="$(ipmitool sdr type temperature 2>/dev/null)" && [[ -n "$SDR" ]]
}

# ------------ parsers using in-memory SDR ------------
# Hottest temperature anywhere in SDR (robust numeric parse of last field)
hottest_temp_any(){
  awk -F'|' '!/PCH/ {print $NF}' <<< "$SDR" \
  | sed -E 's/[^0-9.]//g;/^$/d' \
  | sort -n | tail -n 1 \
  | awk '{printf "%d\n", ($1+0)}'
}

# IBM bank presence: CPU1/CPU2 with a real temperature reading
ibm_have_cpu1(){
  awk -F'|' '($1 ~ /CPU[[:space:]]*1|CPU1/) && ($1 ~ /Temp/) && ($5 ~ /degrees[[:space:]]*C/i) {f=1}
             END{if(f)print 1}' <<< "$SDR"
}
ibm_have_cpu2(){
  awk -F'|' '($1 ~ /CPU[[:space:]]*2|CPU2/) && ($1 ~ /Temp/) && ($5 ~ /degrees[[:space:]]*C/i) {f=1}
             END{if(f)print 1}' <<< "$SDR"
}

# ------------ % helpers ------------
compute_from_baseline(){
  local t="$1" err want
  err=$(( t - BASELINE_C ))

  if (( DEADBAND_C > 0 )); then
    local abserr=$(( err<0 ? -err : err ))
    if (( abserr <= DEADBAND_C )); then echo "$MIN_PCT"; return; fi
  fi

  if (( err >= 0 )); then
    want=$(( MIN_PCT + UP_GAIN * err ))
  else
    err=$(( -err ))
    want=$(( MIN_PCT - DOWN_GAIN * err ))
  fi
  (( want < MIN_PCT )) && want="$MIN_PCT"
  (( want > MAX_PCT )) && want="$MAX_PCT"
  echo "$want"
}
apply_slew(){
  local last="$1" want="$2" delta
  (( SLEW_PCT == 0 )) && { echo "$want"; return; }
  delta=$(( want - last ))
  if   (( delta >  SLEW_PCT )); then echo $(( last + SLEW_PCT ))
  elif (( delta < -SLEW_PCT )); then echo $(( last - SLEW_PCT ))
  else echo "$want"; fi
}

# ------------ IBM % → hex ------------
ibm_hex_for_pct(){
  local p=$1
  (( p<0 )) && p=0; (( p>100 )) && p=100
  if [[ "$IBM_CODEMAP" = "linear" ]]; then
    # 0..100% → 0x12..0xFF (rounded)
    local min_dec=$((16#12)) max_dec=$((16#FF)) span
    span=$(( max_dec - min_dec ))
    local code=$(( min_dec + (p * span + 50) / 100 ))
    (( code < min_dec )) && code=$min_dec
    (( code > max_dec )) && code=$max_dec
    printf "0x%02X\n" "$code"
  else
    # classic steps
    if   (( p <= 0 ));  then echo 0x12
    elif (( p <= 25 )); then echo 0x30
    elif (( p <= 30 )); then echo 0x35
    elif (( p <= 35 )); then echo 0x3A
    elif (( p <= 40 )); then echo 0x40
    elif (( p <= 50 )); then echo 0x50
    elif (( p <= 60 )); then echo 0x60
    elif (( p <= 70 )); then echo 0x70
    elif (( p <= 80 )); then echo 0x80
    elif (( p <= 90 )); then echo 0x90
    elif (( p <= 95 )); then echo 0xA0
    else                   echo 0xFF
    fi
  fi
}

# ------------ writers ------------
set_ibm_bank(){ local bank="$1" pct="$2" hx; hx="$(ibm_hex_for_pct "$pct")"; ipmitool raw 0x3a 0x07 "$bank" "$hx" 0x01; }
pct_to_hex(){ local p="$1"; (( p<0 )) && p=0; (( p>100 )) && p=100; printf "0x%02x" "$p"; }
set_dell_global(){ local pct="$1" hx; hx="$(pct_to_hex "$pct")"; ipmitool raw 0x30 0x30 0x01 0x00; ipmitool raw 0x30 0x30 0x02 0xff "$hx"; }

# ------------ state ------------
CUR_PCT="$MIN_PCT"

# ------------ main loop ------------
while true; do
  # 1) Read SDR
  if ! fetch_ipmi; then
    echo "[$(date +'%F %T')] IPMI read failed; retrying..."
    sleep "$INTERVAL"; continue
  fi

  # 2) Learn which IBM banks exist from THIS snapshot
  if [[ "$VENDOR" == "ibm" ]]; then
    HAVE1="$(ibm_have_cpu1 || true)"
    HAVE2="$(ibm_have_cpu2 || true)"
  fi

  # 3) Post-read keepalive: immediately re-assert current speed (mirrors your manual workflow)
  if [[ "$VENDOR" == "ibm" ]]; then
    HX_KEEP="$(ibm_hex_for_pct "$CUR_PCT")"
    [[ -n "$HAVE1" ]] && ipmitool raw 0x3a 0x07 "$IBM_BANK1" "$HX_KEEP" 0x01 >/dev/null 2>&1 || true
    [[ -n "$HAVE2" ]] && ipmitool raw 0x3a 0x07 "$IBM_BANK2" "$HX_KEEP" 0x01 >/dev/null 2>&1 || true
  else
    set_dell_global "$CUR_PCT" >/dev/null 2>&1 || true
  fi

  # 4) Parse hottest temp, compute and set new target
  HOT="$(hottest_temp_any)"
  if [[ -z "${HOT:-}" ]]; then
    echo "[$(date +'%F %T')] No temperature parsed from SDR; retrying..."
    sleep "$INTERVAL"; continue
  fi

  WANT="$(compute_from_baseline "$HOT")"
  CUR_PCT="$(apply_slew "$CUR_PCT" "$WANT")"

  if [[ "$VENDOR" == "ibm" ]]; then
    [[ -n "$HAVE1" ]] && set_ibm_bank "$IBM_BANK1" "$CUR_PCT"
    [[ -n "$HAVE2" ]] && set_ibm_bank "$IBM_BANK2" "$CUR_PCT"
    echo "[$(date +'%F %T')] IBM: HOT=${HOT}°C -> ${CUR_PCT}% (map=${IBM_CODEMAP}) banks=$([[ -n "$HAVE1" ]] && echo 1)$( [[ -n "$HAVE2" ]] && echo 2)"
  else
    set_dell_global "$CUR_PCT"
    echo "[$(date +'%F %T')] Dell/clone: HOT=${HOT}°C -> ${CUR_PCT}%"
  fi

  sleep "$INTERVAL"
done
FANEOF
}

write_defaults() {
  cat > "${DEFAULTS_PATH}" <<'DFEOF'
# /etc/default/fan-control
# Override environment variables for fan_control.service here.
# Remove the leading '#' to activate a setting; defaults are in the script.

#INTERVAL=30
#BASELINE_C=45
#UP_GAIN=2
#DOWN_GAIN=1
#MIN_PCT=0
#MAX_PCT=60
#SLEW_PCT=15
#DEADBAND_C=0

# IBM mapping: "table" (classic steps) or "linear" (0x12..0xFF)
#IBM_CODEMAP=linear

# IBM banks (usually fine as-is)
#IBM_BANK1=0x01
#IBM_BANK2=0x02
DFEOF
  chmod 0644 "${DEFAULTS_PATH}"
}

write_service() {
  cat > "${SERVICE_PATH}" <<SVC
[Unit]
Description=Baseline-reactive Fan Control (IBM & Dell/Unisys)
After=multi-user.target

[Service]
Type=simple
ExecStart=${SCRIPT_PATH}
EnvironmentFile=-${DEFAULTS_PATH}
Restart=always
RestartSec=3
User=root

# Keep hardening minimal to avoid blocking ipmitool access
NoNewPrivileges=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
SVC
}

enable_service() {
  systemctl daemon-reload
  systemctl enable --now fan-control.service
}

summary() {
  echo
  echo "Installed:"
  echo "  Script : ${SCRIPT_PATH}"
  echo "  Service: ${SERVICE_PATH}"
  echo "  Env    : ${DEFAULTS_PATH} (edit to tweak settings)"
  echo
  echo "Commands:"
  echo "  journalctl -u fan-control.service -f"
  echo "  sudo systemctl edit fan-control.service      # add overrides (optional)"
  echo "  sudo systemctl restart fan-control.service"
}

main() {
  need_root
  install_deps
  write_script
  write_defaults
  write_service
  enable_service
  summary
}

main "$@"
