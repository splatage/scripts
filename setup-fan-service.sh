#!/bin/bash
# setup-fan-service.sh
# Installs a target-temp (PI) fan controller with quiet-cap, IBM per-bank + Dell global,
# IBM-safe IPMI calls, step stickiness (anti-drift), Prometheus export, systemd service.

set -euo pipefail
IFS=$'\n\t'

FAN_SCRIPT_PATH="/usr/local/sbin/fan_control.sh"
SERVICE_NAME="fan-control.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
METRICS_DIR="/var/lib/node_exporter/textfile_collector"
METRICS_FILE="${METRICS_DIR}/fan_control.prom"

echo "[1/5] Ensuring prerequisites..."
need_pkgs=()
command -v ipmitool >/dev/null 2>&1 || need_pkgs+=(ipmitool)
command -v dmidecode >/dev/null 2>&1 || need_pkgs+=(dmidecode)
if ((${#need_pkgs[@]})); then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y "${need_pkgs[@]}"
  else
    echo "Missing: ${need_pkgs[*]} (and apt-get unavailable). Install them and re-run." >&2
    exit 1
  fi
fi

echo "[2/5] Preparing Prometheus textfile collector path: ${METRICS_DIR}"
mkdir -p "${METRICS_DIR}"
chmod 755 "${METRICS_DIR}"

echo "[3/5] Installing ${FAN_SCRIPT_PATH}"
install -m 0755 /dev/stdin "${FAN_SCRIPT_PATH}" <<'FANEOF'
#!/bin/bash
# fan_control.sh — target-temp PI controller with IBM/Dell paths + quiet cap
# IBM path hardened: safe IPMI wrapper, step-stickiness to prevent audible drift.

set -o errexit -o nounset -o pipefail
IFS=$'\n\t'

# ---------------- Env-configurable knobs ----------------
# Vendor path: "ibm" or "dell" (auto-detect if unset)
VENDOR="${FANCTL_VENDOR:-}"

# Sensors: prefer SDR IDs on platforms with duplicate/generic labels (e.g., Unisys)
CPU1_ID="${FANCTL_CPU1_SDR_ID:-}"
CPU2_ID="${FANCTL_CPU2_SDR_ID:-}"
CPU1_LABEL="${FANCTL_CPU1_LABEL:-CPU 1 Temp}"
CPU2_LABEL="${FANCTL_CPU2_LABEL:-CPU 2 Temp}"

# IBM bank IDs (override if your chassis maps differently)
IBM_BANK1="${FANCTL_IBM_BANK1:-0x01}"
IBM_BANK2="${FANCTL_IBM_BANK2:-0x02}"

# Control loop
INTERVAL="${FANCTL_INTERVAL:-30}"      # seconds between loops
TARGET_C="${FANCTL_TARGET_C:-65}"      # desired CPU temperature (°C)
DEADBAND_C="${FANCTL_DEADBAND_C:-2}"   # ±°C around target where we back off
MIN_PCT="${FANCTL_MIN_PCT:-10}"        # min PWM %
MAX_PCT="${FANCTL_MAX_PCT:-80}"        # max PWM %
KP="${FANCTL_KP:-3}"                   # proportional gain: % per °C
KI_mPct_per_s="${FANCTL_KI_MILLI:-0}"  # integral gain (milli-% per °C per second). 0 = off
SLEW_PCT="${FANCTL_SLEW_PCT:-6}"       # max % change per loop

# Quiet cap (acoustics): hold duty low while cool
LOW_CAP_C="${FANCTL_LOW_CAP_C:-50}"             # lift cap once hottest CPU ≥ this temp (°C)
LOW_CAP_MAX_PCT="${FANCTL_LOW_CAP_MAX_PCT:-15}" # max % allowed below LOW_CAP_C
# Tip: ensure MIN_PCT <= LOW_CAP_MAX_PCT for the cap to have effect.

# IBM step stickiness (anti-drift between adjacent steps)
IBM_STEP_STICKY_PCT="${FANCTL_IBM_STEP_STICKY_PCT:-3}"  # require ≥3% margin to switch steps

# Debug logging (0/1)
DEBUG="${FANCTL_DEBUG:-0}"

# ---------------- IBM hex steps (preserved from your original) ----------------
FAN_SPEED_0=0x12
FAN_SPEED_25=0x30
FAN_SPEED_30=0x35
FAN_SPEED_35=0x3A
FAN_SPEED_40=0x40
FAN_SPEED_50=0x50
FAN_SPEED_60=0x60
FAN_SPEED_70=0x70
FAN_SPEED_80=0x80
FAN_SPEED_90=0x90
FAN_SPEED_95=0xA0
FAN_SPEED_100=0xFF

# ---------------- Files ----------------
IPMI_CACHE_FILE="/tmp/ipmi_temperature_cache.txt"
METRICS_FILE="/var/lib/node_exporter/textfile_collector/fan_control.prom"
LOCK="/tmp/fan_control.lock"

# ---------------- Single-instance lock ----------------
exec 9>"$LOCK"
if ! flock -n 9; then
  echo "Another fan_control instance is running. Exiting."
  exit 0
fi

# ---------------- Vendor detect (simple) ----------------
detect_vendor_simple() {
  local man prod base
  man="$(dmidecode -s system-manufacturer 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
  prod="$(dmidecode -s system-product-name 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
  base="$(dmidecode -s baseboard-manufacturer 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
  local s="${man} ${base} ::: ${prod}"
  if echo "$s" | grep -Eq 'dell|emc|unisys'; then
    echo dell
  elif echo "$s" | grep -Eq 'ibm|lenovo'; then
    echo ibm
  else
    echo ibm
  fi
}
if [[ -z "$VENDOR" ]]; then VENDOR="$(detect_vendor_simple)"; fi
echo "Vendor path: ${VENDOR}"

# ---------------- IPMI helpers ----------------
fetch_ipmi_data() { ipmitool sdr type temperature > "$IPMI_CACHE_FILE"; }

# Safe IPMI wrapper (retry, don't crash the loop)
safe_ipmi() {
  # usage: safe_ipmi raw 0x.. 0x.. ...
  if ipmitool "$@" >/dev/null 2>&1; then return 0; fi
  sleep 0.2
  if ipmitool "$@" >/dev/null 2>&1; then return 0; fi
  sleep 0.5
  if ipmitool "$@" >/dev/null 2>&1; then return 0; fi
  [[ "$DEBUG" = "1" ]] && echo "WARN: ipmitool $* failed" >&2
  return 1
}

# Read temp by SDR ID (2nd column like "0Eh"). Returns integer °C or empty.
get_temp_by_sdr_id() {
  local id="$1"
  awk -F'|' -v id="$id" 'BEGIN{IGNORECASE=1}
    $2 ~ id { gsub(/[^0-9.]/,"",$5); if($5!="") print int($5+0) }' "$IPMI_CACHE_FILE" | head -n1
}
# Read temp by label (1st column, exact match). Returns integer °C or empty.
get_temp_by_label() {
  local label="$1"
  awk -F'|' -v lab="$label" '$1==lab { gsub(/[^0-9.]/,"",$5); if($5!="") print int($5+0) }' "$IPMI_CACHE_FILE" | head -n1
}

# ---------------- Percent/Hex mapping ----------------
# Nearest-up step (safety) — raw table -> hex
hex_for_step_pct_ibm() {
  local step=$1
  case "$step" in
    0) echo $FAN_SPEED_0 ;;
    25) echo $FAN_SPEED_25 ;;
    30) echo $FAN_SPEED_30 ;;
    35) echo $FAN_SPEED_35 ;;
    40) echo $FAN_SPEED_40 ;;
    50) echo $FAN_SPEED_50 ;;
    60) echo $FAN_SPEED_60 ;;
    70) echo $FAN_SPEED_70 ;;
    80) echo $FAN_SPEED_80 ;;
    90) echo $FAN_SPEED_90 ;;
    95) echo $FAN_SPEED_95 ;;
    100) echo $FAN_SPEED_100 ;;
    *) echo $FAN_SPEED_40 ;;
  esac
}
# Quantize a % to IBM step with stickiness against toggling
quantize_ibm_pct() {
  local p="$1" last_step="$2"
  # ceil to supported steps
  local step
  if   (( p <= 0  )); then step=0
  elif (( p <= 25 )); then step=25
  elif (( p <= 30 )); then step=30
  elif (( p <= 35 )); then step=35
  elif (( p <= 40 )); then step=40
  elif (( p <= 50 )); then step=50
  elif (( p <= 60 )); then step=60
  elif (( p <= 70 )); then step=70
  elif (( p <= 80 )); then step=80
  elif (( p <= 90 )); then step=90
  elif (( p <= 95 )); then step=95
  else                    step=100
  fi
  # Stickiness: require margin to change from last_step
  if [[ -n "$last_step" && "$last_step" -ne 0 ]]; then
    if (( step > last_step )); then
      # going up: require p >= last_step + IBM_STEP_STICKY_PCT
      if (( p < last_step + IBM_STEP_STICKY_PCT )); then step="$last_step"; fi
    elif (( step < last_step )); then
      # going down: require p <= step - IBM_STEP_STICKY_PCT
      if (( p > step - IBM_STEP_STICKY_PCT )); then step="$last_step"; fi
    fi
  fi
  echo "$step"
}

pct_to_hex_dell() { local p=$1; ((p<0))&&p=0; ((p>100))&&p=100; printf "0x%02x" "$p"; }

# ---------------- Command writers ----------------
# IBM per-bank (safe wrapper + debug)
ibm_set_bank_pct() {
  local bank="$1" pct="$2" step="$3" hx
  hx="$(hex_for_step_pct_ibm "$step")"
  if [[ "$DEBUG" = "1" ]]; then
    echo "IBM set bank ${bank}: pct=${pct}% -> step=${step}% -> hex=${hx}"
  fi
  if ! safe_ipmi raw 0x3a 0x07 "$bank" "$hx" 0x01; then
    echo "WARN: IBM set bank ${bank} failed (pct=${pct} step=${step})" >&2
  fi
}

# Dell/Unisys global with manual/auto (safe wrapper + debug)
dell_manual=0
dell_enter_manual() {
  safe_ipmi raw 0x30 0x30 0x01 0x00 || true
  dell_manual=1
}
dell_restore_auto() { safe_ipmi raw 0x30 0x30 0x01 0x01 || true; }
dell_set_pct() {
  local pct="$1"; local hx; hx="$(pct_to_hex_dell "$pct")"
  [[ "$DEBUG" = "1" ]] && echo "Dell set global: pct=${pct}% hex=${hx}"
  safe_ipmi raw 0x30 0x30 0x02 0xff "$hx" || true
}

cleanup() {
  if [[ "$VENDOR" == "dell" && $dell_manual -eq 1 ]]; then
    echo "Restoring auto fan control..."; dell_restore_auto
  fi
}
trap cleanup EXIT INT TERM

# ---------------- PI Controller ----------------
LAST1=0; LAST2=0; LASTG=0           # last applied % (IBM uses step % here)
IERR1=0; IERR2=0; IERRG=0
LAST1_STEP=""; LAST2_STEP=""         # last IBM step % (for stickiness)

clamp() { local v=$1 lo=$2 hi=$3; (( v<lo )) && v=$lo; (( v>hi )) && v=$hi; echo "$v"; }

# compute_next_pct temp last% IERR_REF
compute_next_pct() {
  local temp="$1" last="$2" ierr_ref="$3"  # name of integral variable (IERR1/IERR2/IERRG)
  local err=$(( temp - TARGET_C ))
  local abs_err=${err#-}

  # Deadband: gently drift toward MIN
  if (( abs_err <= DEADBAND_C )); then
    local down=$(( last - 1 ))
    last="$(clamp "$down" "$MIN_PCT" "$MAX_PCT")"
    # Quiet cap
    if (( temp < LOW_CAP_C )) && (( last > LOW_CAP_MAX_PCT )); then
      last="$LOW_CAP_MAX_PCT"
    fi
    printf "%d\n" "$last"; return
  fi

  # Proportional
  local pterm=$(( KP * err ))

  # Integral (milli-%)
  local add_milli=$(( KI_mPct_per_s * err * INTERVAL ))
  local cur_i; eval "cur_i=\${$ierr_ref}"
  cur_i=$(( cur_i + add_milli ))
  local i_clamp=$(( MAX_PCT*1000 ))
  (( cur_i >  i_clamp )) && cur_i=$i_clamp
  (( cur_i < -i_clamp )) && cur_i=-i_clamp
  eval "$ierr_ref=$cur_i"
  local iterm=$(( cur_i / 1000 ))

  # Raw target
  local want=$(( last + pterm + iterm ))
  want="$(clamp "$want" "$MIN_PCT" "$MAX_PCT")"

  # Slew limit
  local delta=$(( want - last ))
  if   (( delta >  SLEW_PCT )); then want=$(( last + SLEW_PCT ))
  elif (( delta < -SLEW_PCT )); then want=$(( last - SLEW_PCT ))
  fi
  want="$(clamp "$want" "$MIN_PCT" "$MAX_PCT")"

  # Quiet cap (below threshold)
  if (( temp < LOW_CAP_C )) && (( want > LOW_CAP_MAX_PCT )); then
    want="$LOW_CAP_MAX_PCT"
  fi

  printf "%d\n" "$want"
}

# ---------------- Main ----------------
# Vendor detect (simple) if not set
detect_vendor_simple() {
  local man prod base
  man="$(dmidecode -s system-manufacturer 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
  prod="$(dmidecode -s system-product-name 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
  base="$(dmidecode -s baseboard-manufacturer 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
  local s="${man} ${base} ::: ${prod}"
  if echo "$s" | grep -Eq 'dell|emc|unisys'; then echo dell
  elif echo "$s" | grep -Eq 'ibm|lenovo'; then echo ibm
  else echo ibm; fi
}
if [[ -z "$VENDOR" ]]; then VENDOR="$(detect_vendor_simple)"; fi
echo "Vendor path: ${VENDOR}"
if [[ "$VENDOR" == "dell" ]]; then
  echo "Entering manual fan control (Dell-class)..."; dell_enter_manual
fi

while true; do
  echo "Fetching IPMI data..."
  if ! fetch_ipmi_data; then
    echo "Failed to fetch IPMI data. Retrying..."; sleep 10; continue
  fi

  # Read temps
  CPU1_TEMP=""; CPU2_TEMP=""
  if [[ -n "$CPU1_ID" ]]; then CPU1_TEMP="$(get_temp_by_sdr_id "$CPU1_ID" || true)"; else CPU1_TEMP="$(get_temp_by_label "$CPU1_LABEL" || true)"; fi
  if [[ -n "$CPU2_ID" ]]; then CPU2_TEMP="$(get_temp_by_sdr_id "$CPU2_ID" || true)"; else CPU2_TEMP="$(get_temp_by_label "$CPU2_LABEL" || true)"; fi

  if [[ -z "$CPU1_TEMP" && -z "$CPU2_TEMP" ]]; then
    echo "No CPU temperature readings (check labels/IDs). Retrying..."; sleep 10; continue
  fi

  if [[ "$VENDOR" == "ibm" ]]; then
    # Per-bank control with IBM step stickiness
    if [[ -n "$CPU1_TEMP" ]]; then
      local_want="$(compute_next_pct "$CPU1_TEMP" "$LAST1" IERR1)"
      # convert to sticky IBM step %
      NEXT1_STEP="$(quantize_ibm_pct "$local_want" "${LAST1_STEP:-}")"
      LAST1="$NEXT1_STEP"; LAST1_STEP="$NEXT1_STEP"
      ibm_set_bank_pct "$IBM_BANK1" "$local_want" "$NEXT1_STEP"
    fi
    if [[ -n "$CPU2_TEMP" ]]; then
      local_want2="$(compute_next_pct "$CPU2_TEMP" "$LAST2" IERR2)"
      NEXT2_STEP="$(quantize_ibm_pct "$local_want2" "${LAST2_STEP:-}")"
      LAST2="$NEXT2_STEP"; LAST2_STEP="$NEXT2_STEP"
      ibm_set_bank_pct "$IBM_BANK2" "$local_want2" "$NEXT2_STEP"
    fi
  else
    # Global (Dell/Unisys): regulate to hottest CPU
    HOT=$(( ${CPU1_TEMP:-0} > ${CPU2_TEMP:-0} ? ${CPU1_TEMP:-0} : ${CPU2_TEMP:-0} ))
    local_wantg="$(compute_next_pct "$HOT" "$LASTG" IERRG)"
    LASTG="$local_wantg"
    dell_set_pct "$LASTG"
  fi

  # Status
  echo "----------------------------------"
  echo "Fan Control (target=${TARGET_C}°C, deadband=±${DEADBAND_C}°C, min=${MIN_PCT}%, max=${MAX_PCT}%)"
  echo "Quiet cap: ≤${LOW_CAP_MAX_PCT}% while hot_cpu < ${LOW_CAP_C}°C"
  echo "CPU 1 (${CPU1_ID:-$CPU1_LABEL}): ${CPU1_TEMP:-N/A}°C"
  echo "CPU 2 (${CPU2_ID:-$CPU2_LABEL}): ${CPU2_TEMP:-N/A}°C"
  if [[ "$VENDOR" == "ibm" ]]; then
    echo "Applied IBM per-bank: Bank1=${LAST1}% Bank2=${LAST2}% (sticky ±${IBM_STEP_STICKY_PCT}%)"
  else
    echo "Applied Dell global: ${LASTG}% (hot=${HOT}°C)"
  fi
  echo "Last updated: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "----------------------------------"

  # Metrics
  umask 022
  {
    [[ -n "$CPU1_TEMP" ]] && echo "fanctl_cpu1_temp_c ${CPU1_TEMP}"
    [[ -n "$CPU2_TEMP" ]] && echo "fanctl_cpu2_temp_c ${CPU2_TEMP}"
    echo "fanctl_target_c ${TARGET_C}"
    echo "fanctl_deadband_c ${DEADBAND_C}"
    echo "fanctl_min_pct ${MIN_PCT}"
    echo "fanctl_max_pct ${MAX_PCT}"
    echo "fanctl_kp ${KP}"
    echo "fanctl_ki_milli ${KI_mPct_per_s}"
    echo "fanctl_slew_pct ${SLEW_PCT}"
    echo "fanctl_low_cap_c ${LOW_CAP_C}"
    echo "fanctl_low_cap_max_pct ${LOW_CAP_MAX_PCT}"
    if [[ "$VENDOR" == "ibm" ]]; then
      echo "fanctl_fan1_step_pct ${LAST1}"
      echo "fanctl_fan2_step_pct ${LAST2}"
    else
      echo "fanctl_fan_global_pct ${LASTG}"
    fi
    echo "fanctl_vendor{vendor=\"${VENDOR}\"} 1"
    echo "fanctl_interval_seconds ${INTERVAL}"
    echo "fanctl_up 1"
  } > "${METRICS_FILE}.tmp" && mv "${METRICS_FILE}.tmp" "${METRICS_FILE}"

  sleep "${INTERVAL}"
done
FANEOF

echo "[4/5] Creating systemd service at ${SERVICE_PATH}"
cat > "${SERVICE_PATH}" <<SERVICEEOF
[Unit]
Description=Target-temp Fan Control (IBM per-bank / Dell global) + Prometheus export
After=network-online.target

[Service]
Type=simple
ExecStart=${FAN_SCRIPT_PATH}
Restart=always
RestartSec=5
User=root
NoNewPrivileges=yes
ProtectSystem=full
ProtectHome=yes
PrivateTmp=yes

# -------- Optional tuning (uncomment & adjust) --------
# Vendor (auto-detect if unset)
#Environment=FANCTL_VENDOR=ibm
#Environment=FANCTL_VENDOR=dell

# IBM labels (typical):
#Environment=FANCTL_CPU1_LABEL=CPU\ 1\ Temp
#Environment=FANCTL_CPU2_LABEL=CPU\ 2\ Temp
# IBM bank overrides (if needed):
#Environment=FANCTL_IBM_BANK1=0x01
#Environment=FANCTL_IBM_BANK2=0x02

# Dell/Unisys (use SDR IDs to disambiguate generic "Temp"):
#Environment=FANCTL_CPU1_SDR_ID=0Eh
#Environment=FANCTL_CPU2_SDR_ID=0Fh

# Control targets & dynamics (quiet defaults)
#Environment=FANCTL_TARGET_C=65
#Environment=FANCTL_DEADBAND_C=4
#Environment=FANCTL_MIN_PCT=10
#Environment=FANCTL_MAX_PCT=60
#Environment=FANCTL_KP=2
#Environment=FANCTL_KI_MILLI=0
#Environment=FANCTL_SLEW_PCT=3
#Environment=FANCTL_INTERVAL=20

# Quiet cap (≤15% until hottest CPU ≥ 50°C)
#Environment=FANCTL_LOW_CAP_C=50
#Environment=FANCTL_LOW_CAP_MAX_PCT=15

# IBM anti-drift (step stickiness, default 3%)
#Environment=FANCTL_IBM_STEP_STICKY_PCT=3

# Debug logs
#Environment=FANCTL_DEBUG=1

[Install]
WantedBy=multi-user.target
SERVICEEOF

echo "[5/5] Enabling and starting service..."
systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}"

echo
echo "Done."
echo "Edit env overrides:  systemctl edit ${SERVICE_NAME}"
echo "Logs (follow):       journalctl -u ${SERVICE_NAME} -f"
echo "Metrics file:        ${METRICS_FILE}"
