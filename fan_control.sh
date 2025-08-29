#!/bin/bash
# /usr/local/sbin/fan_control_simple.sh
# Baseline-referenced fan control for IBM (step or linear hex) and Dell/Unisys (percent).
# pct each cycle is based on TEMP vs BASELINE (not last delta), then clamped & slewed.
# IBM_CODEMAP: "table" (default, classic codes) or "linear" (0x12..0xFF).

set -u -o pipefail
IFS=$'\n\t'
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ------------ single-instance lock ------------
LOCKFILE="/var/run/fan_control_simple.lock"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
  echo "[$(date +'%F %T')] already running (lock $LOCKFILE). Exiting. PID=$$"
  exit 0
fi

# ------------ tuning knobs ------------
INTERVAL=${INTERVAL:-30}        # seconds between checks
BASELINE_C=${BASELINE_C:-45}    # target "quiet" temperature (°C)
UP_GAIN=${UP_GAIN:-5}           # % per +1°C above baseline
DOWN_GAIN=${DOWN_GAIN:-1}       # % per -1°C below baseline
MIN_PCT=${MIN_PCT:-10}          # min applied % (quiet floor)
MAX_PCT=${MAX_PCT:-60}          # max applied % (raise if needed)
SLEW_PCT=${SLEW_PCT:-15}        # max % change per cycle (0 = unlimited)
DEADBAND_C=${DEADBAND_C:-0}     # °C around baseline to ignore (0 = off)

# IBM mapping mode: "table" (classic codes) or "linear" (0x12..0xFF)
IBM_CODEMAP="${IBM_CODEMAP:-table}"

# IBM sensor labels & banks (match your SDR)
CPU1_LABEL="${CPU1_LABEL:-CPU 1 Temp}"
CPU2_LABEL="${CPU2_LABEL:-CPU 2 Temp}"
IBM_BANK1="${IBM_BANK1:-0x01}"
IBM_BANK2="${IBM_BANK2:-0x02}"

IPMI_CACHE="/tmp/ipmi_temp_cache.txt"

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

# ------------ IPMI reads ------------
fetch_ipmi(){ ipmitool sdr type temperature > "$IPMI_CACHE"; }

# IBM: exact original label read → integer °C (empty if none)
get_temp_label_ibm(){
  local label="$1"
  grep -w "$label" "$IPMI_CACHE" \
    | awk -F'|' '{gsub(/[^0-9.]/,"",$5); if($5!="") printf "%d\n",$5+0}' \
    | head -n1
}

# Dell/Unisys: hottest sensible sensor
get_hottest_temp_generic(){
  awk -F'|' '
    BEGIN{IGNORECASE=1; max=-1}
    {
      lab=$1; gsub(/^[ \t]+|[ \t]+$/,"",lab)
      val=$5; gsub(/[^0-9.]/,"",val)
      if (val=="") next
      if (lab ~ /(inlet|exhaust|ambient|pch|vr|vreg|dimm|psu|supply|backplane|board|system)/) next
      n=int(val+0)
      if (n>max) max=n
    }
    END{ if (max>=0) print max }' "$IPMI_CACHE"
}

# ------------ % helpers ------------
compute_from_baseline(){
  # args: tempC
  local t="$1" err want
  err=$(( t - BASELINE_C ))

  # deadband: stay at MIN_PCT if within ±DEADBAND_C
  if (( DEADBAND_C > 0 )); then
    local abserr=$(( err<0 ? -err : err ))
    if (( abserr <= DEADBAND_C )); then
      echo "$MIN_PCT"; return
    fi
  fi

  if (( err >= 0 )); then
    want=$(( MIN_PCT + UP_GAIN * err ))
  else
    err=$(( -err ))  # degrees below baseline
    want=$(( MIN_PCT - DOWN_GAIN * err ))
  fi

  (( want < MIN_PCT )) && want="$MIN_PCT"
  (( want > MAX_PCT )) && want="$MAX_PCT"
  echo "$want"
}

apply_slew(){
  # args: last_pct desired_pct
  local last="$1" want="$2" delta
  (( SLEW_PCT == 0 )) && { echo "$want"; return; }
  delta=$(( want - last ))
  if   (( delta >  SLEW_PCT )); then echo $(( last + SLEW_PCT ))
  elif (( delta < -SLEW_PCT )); then echo $(( last - SLEW_PCT ))
  else echo "$want"; fi
}

# ------------ IBM mapping: % → hex ------------
ibm_hex_for_pct(){
  local p=$1
  (( p<0 )) && p=0; (( p>100 )) && p=100

  if [[ "$IBM_CODEMAP" = "linear" ]]; then
    # Map 0..100% → 0x12..0xFF linearly (rounded)
    local min_dec=$((16#12)) max_dec=$((16#FF))
    local span=$(( max_dec - min_dec ))  # 237
    local code=$(( min_dec + (p * span + 50) / 100 ))
    (( code < min_dec )) && code=$min_dec
    (( code > max_dec )) && code=$max_dec
    printf "0x%02X\n" "$code"
  else
    # Classic “safe” step table
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
VENDOR="$(detect_vendor)"
echo "[$(date +'%F %T')] starting fan_control_simple (PID=$$) vendor=$VENDOR baseline=${BASELINE_C}C IBM_CODEMAP=${IBM_CODEMAP}"

CUR_PCT="$MIN_PCT"
HAVE_CPU1=0; HAVE_CPU2=0

# ------------ main loop ------------
while true; do
  if ! fetch_ipmi; then
    echo "[$(date +'%F %T')] IPMI read failed; retrying..."
    sleep "$INTERVAL"; continue
  fi

  if [[ "$VENDOR" == "ibm" ]]; then
    T1="$(get_temp_label_ibm "$CPU1_LABEL")"
    T2="$(get_temp_label_ibm "$CPU2_LABEL")"
    [[ -n "$T1" ]] && HAVE_CPU1=1
    [[ -n "$T2" ]] && HAVE_CPU2=1

    HOT=0
    [[ -n "$T1" && "$T1" -gt "$HOT" ]] && HOT="$T1"
    [[ -n "$T2" && "$T2" -gt "$HOT" ]] && HOT="$T2"
    if (( HOT == 0 )) && [[ -z "$T1" && -z "$T2" ]]; then
      echo "[$(date +'%F %T')] IBM: no CPU temps; retrying..."
      sleep "$INTERVAL"; continue
    fi

    WANT="$(compute_from_baseline "$HOT")"
    CUR_PCT="$(apply_slew "$CUR_PCT" "$WANT")"

    [[ $HAVE_CPU1 -eq 1 ]] && set_ibm_bank "$IBM_BANK1" "$CUR_PCT"
    [[ $HAVE_CPU2 -eq 1 ]] && set_ibm_bank "$IBM_BANK2" "$CUR_PCT"

    echo "[$(date +'%F %T')] IBM: HOT=${HOT}°C  err=$((HOT-BASELINE_C))°C  -> ${CUR_PCT}% (map=${IBM_CODEMAP})"

  else
    HOT="$(get_hottest_temp_generic)"
    if [[ -z "$HOT" ]]; then
      echo "[$(date +'%F %T')] Dell/clone: no sensible temperature; retrying..."
      sleep "$INTERVAL"; continue
    fi

    WANT="$(compute_from_baseline "$HOT")"
    CUR_PCT="$(apply_slew "$CUR_PCT" "$WANT")"
    set_dell_global "$CUR_PCT"

    echo "[$(date +'%F %T')] Dell/clone: HOT=${HOT}°C  err=$((HOT-BASELINE_C))°C  -> ${CUR_PCT}%"
  fi

  sleep "$INTERVAL"
done
