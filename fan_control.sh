#!/bin/bash
# /usr/local/sbin/fan_control.sh
# Baseline-referenced fan control for IBM (step or linear hex) and Dell/Unisys (percent).
# pct each cycle is based on TEMP vs BASELINE (not last delta), then clamped & slewed.
# IBM_CODEMAP: "table" (default, classic codes) or "linear" (0x12..0xFF).

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
MIN_PCT=${MIN_PCT:-0}          # min %
MAX_PCT=${MAX_PCT:-60}          # max %
SLEW_PCT=${SLEW_PCT:-15}        # per-cycle max % change (0=off)
DEADBAND_C=${DEADBAND_C:-0}     # °C around baseline to keep MIN_PCT (0=off)

IBM_CODEMAP="${IBM_CODEMAP:-linear}"  # table|linear
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
VENDOR="$(detect_vendor)"
echo "[$(date +'%F %T')] start vendor=$VENDOR baseline=${BASELINE_C}C IBM_CODEMAP=${IBM_CODEMAP}"

# ------------ IPMI read & parsers ------------
fetch_ipmi(){ ipmitool sdr type temperature > "$IPMI_CACHE"; }

# IBM basic CPU temps: your simple pipeline
# - select lines with "CPU" anywhere
# - field 5 contains "NN degrees C" (or "No Reading"/"Transition ...")
# - strip non-digits; drop empties
ibm_hot_cpu_temp(){
  awk -F'|' '/CPU/ {print $5}' "$IPMI_CACHE" \
  | sed -E 's/[^0-9]+//g;/^$/d' \
  | awk 'BEGIN{m=-1} {n=$1+0; if(n>m)m=n} END{if(m>=0)print m}'
}

# IBM bank presence: does CPU1/CPU2 have a *real* reading?
# (filters out "No Reading" and "Transition to OK")
ibm_have_cpu1(){
  awk -F'|' '($1 ~ /CPU[[:space:]]*1|CPU1/) && ($1 ~ /Temp/) && ($5 !~ /No Reading|Transition/) {f=1}
             END{if(f)print 1}' "$IPMI_CACHE"
}
ibm_have_cpu2(){
  awk -F'|' '($1 ~ /CPU[[:space:]]*2|CPU2/) && ($1 ~ /Temp/) && ($5 !~ /No Reading|Transition/) {f=1}
             END{if(f)print 1}' "$IPMI_CACHE"
}

# Dell/Unisys: hottest sensible sensor (ignore inlet/exhaust/ambient/VR/DIMM/PSU/etc.)
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
  if ! fetch_ipmi; then
    echo "[$(date +'%F %T')] IPMI read failed; retrying..."
    sleep "$INTERVAL"; continue
  fi

  if [[ "$VENDOR" == "ibm" ]]; then
    HOT="$(ibm_hot_cpu_temp || true)"
    if [[ -z "${HOT:-}" ]]; then
      echo "[$(date +'%F %T')] IBM: no CPU temps (from /CPU/); retrying..."
      sleep "$INTERVAL"; continue
    fi

    WANT="$(compute_from_baseline "$HOT")"
    CUR_PCT="$(apply_slew "$CUR_PCT" "$WANT")"

    HAVE1="$(ibm_have_cpu1 || true)"
    HAVE2="$(ibm_have_cpu2 || true)"
    [[ -n "$HAVE1" ]] && set_ibm_bank "$IBM_BANK1" "$CUR_PCT"
    [[ -n "$HAVE2" ]] && set_ibm_bank "$IBM_BANK2" "$CUR_PCT"

    echo "[$(date +'%F %T')] IBM: HOT=${HOT}°C -> ${CUR_PCT}% (map=${IBM_CODEMAP}) banks=$([[ -n "$HAVE1" ]] && echo 1)$( [[ -n "$HAVE2" ]] && echo 2)"

  else
    HOT="$(get_hottest_temp_generic)"
    if [[ -z "${HOT:-}" ]]; then
      echo "[$(date +'%F %T')] Dell/clone: no sensible temp; retrying..."
      sleep "$INTERVAL"; continue
    fi

    WANT="$(compute_from_baseline "$HOT")"
    CUR_PCT="$(apply_slew "$CUR_PCT" "$WANT")"
    set_dell_global "$CUR_PCT"
    echo "[$(date +'%F %T')] Dell/clone: HOT=${HOT}°C -> ${CUR_PCT}%"
  fi

  sleep "$INTERVAL"
done
