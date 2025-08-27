#!/bin/bash
# setup-fan-service.sh
# One-shot installer: fan control (IBM + Dell R720), Prometheus export, systemd service.
# - Preserves your IBM logic/values/thresholds AS-IS
# - Adds Dell R720 OEM control with auto/manual toggle and percent→hex mapping
# - Exposes Prometheus textfile metrics
# - Locks to a single instance
# - Auto-detects 1 vs 2 CPUs (same as before)

set -euo pipefail
IFS=$'\n\t'

# --- Paths / constants ---
FAN_SCRIPT_PATH="/usr/local/sbin/fan_control.sh"
SERVICE_NAME="fan-control.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
METRICS_DIR="/var/lib/node_exporter/textfile_collector"
METRICS_FILE="${METRICS_DIR}/fan_control.prom"
INTERVAL_SECS=30

echo "[1/7] Ensuring dependencies..."
need_pkgs=()
command -v ipmitool >/dev/null 2>&1 || need_pkgs+=(ipmitool)
command -v dmidecode >/dev/null 2>&1 || need_pkgs+=(dmidecode)
if ((${#need_pkgs[@]})); then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y "${need_pkgs[@]}"
  else
    echo "Missing: ${need_pkgs[*]} (and apt-get unavailable). Install them and re-run."
    exit 1
  fi
fi

echo "[2/7] Creating Prometheus textfile collector path: ${METRICS_DIR}"
mkdir -p "${METRICS_DIR}"
chmod 755 "${METRICS_DIR}"

echo "[3/7] Installing unified fan control script to ${FAN_SCRIPT_PATH}"
install -m 0755 /dev/stdin "${FAN_SCRIPT_PATH}" <<'FANEOF'
#!/bin/bash
# fan_control.sh
# Unified: IBM (source-of-truth logic preserved) + Dell R720 (OEM RAW control)
# Adds: platform detection, Prometheus metrics, lockfile, --once/--interval flags

set -o errexit -o nounset -o pipefail
IFS=$'\n\t'

# --- CLI flags ---
INTERVAL=30
RUN_ONCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --once) RUN_ONCE=1 ;;
    --interval) shift; INTERVAL="${1:-30}" ;;
    *) echo "Unknown arg: $1"; exit 2 ;;
  esac
  shift
done

# ---------------- IBM (as provided) ----------------
# Fan speed levels (hexadecimal values) — IBM path uses these fixed steps
FAN_SPEED_0=0x12    # 0% fan speed
FAN_SPEED_25=0x30   # 25% fan speed
FAN_SPEED_30=0x35   # 30% fan speed
FAN_SPEED_35=0x3A   # 35% fan speed
FAN_SPEED_40=0x40   # 40% fan speed
FAN_SPEED_50=0x50   # 50% fan speed
FAN_SPEED_60=0x60   # 60% fan speed
FAN_SPEED_70=0x70   # 70% fan speed
FAN_SPEED_80=0x80   # 80% fan speed
FAN_SPEED_90=0x90   # 90% fan speed
FAN_SPEED_100=0xFF  # 100% fan speed (maximum)

# Temperature thresholds (degrees Celsius) — preserved
TEMP_40=40
TEMP_45=45
TEMP_50=50
TEMP_55=55
TEMP_60=60
TEMP_65=65
TEMP_70=70
TEMP_75=75
TEMP_80=80
TEMP_85=85
TEMP_90=90
TEMP_95=95
TEMP_100=100

# Cache + metrics files
IPMI_CACHE_FILE="/tmp/ipmi_temperature_cache.txt"
METRICS_DIR="/var/lib/node_exporter/textfile_collector"
METRICS_FILE="${METRICS_DIR}/fan_control.prom"

# Lockfile to avoid multiple instances
LOCK=/tmp/fan_control.lock
exec 9>"$LOCK"
if ! flock -n 9; then
  echo "Another fan_control instance is running. Exiting."
  exit 0
fi

# ---------- Platform detection ----------
# Prefer dmidecode; fallback to ipmitool FRU/MC if needed.
detect_vendor() {
  local v=""
  if command -v dmidecode >/dev/null 2>&1; then
    v="$(dmidecode -s system-manufacturer 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
  fi
  if [[ -z "$v" ]]; then
    v="$(ipmitool mc info 2>/dev/null | awk -F: '/Manufacturer Name/{print tolower($2)}' | xargs || true)"
  fi
  if echo "$v" | grep -q "dell"; then
    echo "dell"
  elif echo "$v" | grep -Eiq "ibm|lenovo"; then
    echo "ibm"
  else
    # Default to ibm behavior (your current production)
    echo "ibm"
  fi
}

PLATFORM="$(detect_vendor)"
echo "Detected platform: ${PLATFORM}"

# ---------- Shared helpers ----------
fetch_ipmi_data() {
  ipmitool sdr type temperature > "$IPMI_CACHE_FILE"
}

get_cpu_temperature() {
  local label=$1
  # Keep your original parsing: field 5 numeric
  grep -w "$label" "$IPMI_CACHE_FILE" | awk -F'|' '{print $5}' | sed 's/[^0-9.]//g'
}

calculate_fan_speed() {
  local temp=$1
  if (( temp < TEMP_40 )); then
    echo 0
  elif (( temp < TEMP_45 )); then
    echo 25
  elif (( temp < TEMP_50 )); then
    echo 30
  elif (( temp < TEMP_55 )); then
    echo 35
  elif (( temp < TEMP_60 )); then
    echo 40
  elif (( temp < TEMP_65 )); then
    echo 50
  elif (( temp < TEMP_70 )); then
    echo 60
  elif (( temp < TEMP_75 )); then
    echo 70
  elif (( temp < TEMP_80 )); then
    echo 80
  elif (( temp < TEMP_85 )); then
    echo 90
  elif (( temp < TEMP_90 )); then
    echo 95
  else
    echo 100
  fi
}

display_status() {
  local cpu1_temp=$1
  local cpu2_temp=$2
  local fan1_speed=$3
  local fan2_speed=$4

  echo "----------------------------------"
  echo "Fan Control Status"
  echo "----------------------------------"
  echo "CPU 1 Temperature: $cpu1_temp°C"
  echo "CPU 2 Temperature: $cpu2_temp°C"
  echo "Fan Bank CPU 1: Speed $fan1_speed%"
  echo "Fan Bank CPU 2: Speed $fan2_speed%"
  echo "----------------------------------"
  echo "Last updated: $(date +"%Y-%m-%d %H:%M:%S")"
  echo "----------------------------------"
}

write_metrics() {
  umask 022
  local tmp="${METRICS_FILE}.tmp"
  {
    [[ -n "${CPU1_TEMP:-}" && "${CPU1_TEMP:-N/A}" != "N/A" ]] && echo "fanctl_cpu1_temp_c ${CPU1_TEMP}"
    [[ -n "${CPU2_TEMP:-}" && "${CPU2_TEMP:-N/A}" != "N/A" ]] && echo "fanctl_cpu2_temp_c ${CPU2_TEMP}"
    [[ -n "${FAN_SPEED_CPU1:-}" && "${FAN_SPEED_CPU1:-N/A}" != "N/A" ]] && echo "fanctl_fan1_pct ${FAN_SPEED_CPU1}"
    [[ -n "${FAN_SPEED_CPU2:-}" && "${FAN_SPEED_CPU2:-N/A}" != "N/A" ]] && echo "fanctl_fan2_pct ${FAN_SPEED_CPU2}"
    echo "fanctl_interval_seconds ${INTERVAL}"
    echo "fanctl_up 1"
    echo "fanctl_platform{vendor=\"${PLATFORM}\"} 1"
  } > "$tmp" && mv "$tmp" "$METRICS_FILE"
}

# ---------- IBM path (your existing approach) ----------
hex_for_pct_ibm() {
  case "$1" in
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
    95) echo 0xA0 ;;
    100) echo $FAN_SPEED_100 ;;
    *) echo $FAN_SPEED_40 ;; # default
  esac
}

set_fan_speed_ibm() {
  local fan_bank="$1" pct="$2"
  local hex_speed
  hex_speed="$(hex_for_pct_ibm "$pct")"
  # Your existing RAW: bank + hex map
  ipmitool raw 0x3a 0x07 "$fan_bank" "$hex_speed" 0x01 >/dev/null
}

# ---------- Dell R720 path (from your dev script) ----------
# Dell requires manual mode before setting duty; restore auto on exit.
DELL_MANUAL_SET=0

dell_enable_auto() {
  ipmitool raw 0x30 0x30 0x01 0x01 >/dev/null || true
}

dell_disable_auto() {
  ipmitool raw 0x30 0x30 0x01 0x00 >/dev/null
}

pct_to_hex_dell() {
  # Clamp 0..100 then print 0x00..0x64
  local p="$1"
  (( p < 0 )) && p=0
  (( p > 100 )) && p=100
  printf "0x%02x" "${p}"
}

set_fan_speed_dell() {
  local _fan_bank_unused="$1" pct="$2"
  # Dell raw ignores bank; single global duty. Sequence:
  #  - Manual mode already set by dell_disable_auto()
  #  - Set duty: ipmitool raw 0x30 0x30 0x02 0xff <duty_hex>
  local duty_hex
  duty_hex="$(pct_to_hex_dell "$pct")"
  ipmitool raw 0x30 0x30 0x02 0xff "${duty_hex}" >/dev/null
}

# Ensure we restore auto on exit for Dell
cleanup() {
  if [[ "${PLATFORM}" == "dell" && "${DELL_MANUAL_SET}" -eq 1 ]]; then
    echo "Restoring Dell auto fan control..."
    dell_enable_auto
  fi
}
trap cleanup EXIT INT TERM

# Platform-agnostic dispatcher
set_fan_speed_platform() {
  local fan_bank="$1" pct="$2"
  if [[ "${PLATFORM}" == "dell" ]]; then
    # Enter manual once
    if [[ "${DELL_MANUAL_SET}" -eq 0 ]]; then
      echo "Switching Dell to manual fan control..."
      dell_disable_auto
      DELL_MANUAL_SET=1
    fi
    set_fan_speed_dell "$fan_bank" "$pct"
  else
    set_fan_speed_ibm "$fan_bank" "$pct"
  fi
}

# ---------- Main loop ----------
while true; do
  echo "Fetching IPMI data..."
  if ! fetch_ipmi_data; then
    echo "Failed to fetch IPMI data. Retrying..."
    sleep 10
    continue
  fi

  echo "Processing... (fetching temperatures and adjusting fan speeds)"
  sleep 10

  # Auto-detect sensors (only control CPUs that exist)
  CPU1_TEMP="$(get_cpu_temperature "CPU 1 Temp" || true)"
  CPU2_TEMP="$(get_cpu_temperature "CPU 2 Temp" || true)"

  if [[ -z "${CPU1_TEMP}" && -z "${CPU2_TEMP}" ]]; then
    echo "No CPU temperature sensors found. Retrying..."
    sleep 10
    continue
  fi

  if [[ -n "${CPU1_TEMP}" ]]; then
    FAN_SPEED_CPU1="$(calculate_fan_speed "${CPU1_TEMP}")"
    # IBM maps CPU1→bank 0x01. Dell ignores bank; we still pass one.
    set_fan_speed_platform 0x01 "${FAN_SPEED_CPU1}"
  else
    FAN_SPEED_CPU1="N/A"
  fi

  if [[ -n "${CPU2_TEMP}" ]]; then
    FAN_SPEED_CPU2="$(calculate_fan_speed "${CPU2_TEMP}")"
    set_fan_speed_platform 0x02 "${FAN_SPEED_CPU2}"
  else
    FAN_SPEED_CPU2="N/A"
  fi

  display_status "${CPU1_TEMP:-N/A}" "${CPU2_TEMP:-N/A}" "${FAN_SPEED_CPU1:-N/A}" "${FAN_SPEED_CPU2:-N/A}"
  write_metrics

  echo "Waiting ${INTERVAL} seconds before the next probe..."
  [[ "${RUN_ONCE}" -eq 1 ]] && exit 0 || sleep "${INTERVAL}"
done
FANEOF

echo "[4/7] Creating systemd service at ${SERVICE_PATH}"
cat > "${SERVICE_PATH}" <<SERVICEEOF
[Unit]
Description=Unified Fan Control (IBM + Dell R720) with Prometheus export
After=network-online.target

[Service]
Type=simple
ExecStart=${FAN_SCRIPT_PATH} --interval ${INTERVAL_SECS}
Restart=always
RestartSec=5
User=root
NoNewPrivileges=yes
ProtectSystem=full
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
SERVICEEOF

echo "[5/7] Reloading systemd..."
systemctl daemon-reload

echo "[6/7] Enabling and starting service..."
systemctl enable --now "${SERVICE_NAME}"

echo "[7/7] Done."
echo
echo "Service:       ${SERVICE_NAME}"
echo "Script:        ${FAN_SCRIPT_PATH}"
echo "Metrics file:  ${METRICS_FILE}"
echo
echo "Follow logs:   journalctl -u ${SERVICE_NAME} -f"
echo "Check metrics: cat ${METRICS_FILE}"
