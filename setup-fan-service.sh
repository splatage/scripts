#!/bin/bash
# fan_control_simple.sh
# Minimal reactive fan controller for IBM (step codes) and Dell/Unisys (percent).
# Logic per 30s tick: +5% per +1°C, -1% per -1°C vs last reading, clamped and slewed.
# IBM uses required predefined step codes; Dell/Unisys accepts a true percent.

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
touch /var/log/fan_control.log && chown root:adm /var/log/fan_control.log

set -u -o pipefail
IFS=$'\n\t'

# -------- Simple tuning knobs --------
INTERVAL=${INTERVAL:-30}        # seconds between checks
BASELINE_C=${BASELINE_C:-45}    # °C, starting comparison point
UP_GAIN=${UP_GAIN:-5}           # % per +1°C
DOWN_GAIN=${DOWN_GAIN:-1}       # % per -1°C
MIN_PCT=${MIN_PCT:-0}          # lower clamp
MAX_PCT=${MAX_PCT:-60}          # upper clamp
SLEW_PCT=${SLEW_PCT:-15}        # max % change per cycle (0 = unlimited)

# IBM labels/banks (must match your SDR labels; banks are typical)
CPU1_LABEL="${CPU1_LABEL:-CPU 1 Temp}"
CPU2_LABEL="${CPU2_LABEL:-CPU 2 Temp}"
IBM_BANK1="${IBM_BANK1:-0x01}"
IBM_BANK2="${IBM_BANK2:-0x02}"

IPMI_CACHE="/tmp/ipmi_temp_cache.txt"

# -------- Vendor detection (simple, robust) --------
lower() { tr '[:upper:]' '[:lower:]'; }
detect_vendor() {
  local man prod base
  man="$(dmidecode -s system-manufacturer 2>/dev/null | lower || true)"
  prod="$(dmidecode -s system-product-name 2>/dev/null | lower || true)"
  base="$(dmidecode -s baseboard-manufacturer 2>/dev/null | lower || true)"
  local s="${man} ${base} ::: ${prod}"
  if echo "$s" | grep -Eq 'dell|emc|unisys'; then echo "dell"
  elif echo "$s" | grep -Eq 'ibm|lenovo'; then echo "ibm"
  else echo "ibm"; fi
}

# -------- IPMI reads --------
fetch_ipmi() { ipmitool sdr type temperature > "$IPMI_CACHE"; }

# IBM: exact, original label read; returns integer °C or empty
get_temp_label_ibm() {
  local label="$1"
  grep -w "$label" "$IPMI_CACHE" \
    | awk -F'|' '{gsub(/[^0-9.]/,"",$5); if($5!="") printf "%d\n",$5+0}' \
    | head -n1
}

# Dell/Unisys: pick hottest "sensible" sensor, ignore inlet/exhaust/ambient/VR/DIMM/PSU/etc.
get_hottest_temp_generic() {
  awk -F'|' '
    BEGIN{IGNORECASE=1; max=-1}
    {
      lab=$1; gsub(/^[ \t]+|[ \t]+$/,"",lab)
      val=$5; gsub(/[^0-9.]/,"",val)
      if (val=="") next
      if (lab ~ /(inlet|exhaust|ambient|pch|vr|vreg|dimm|psu|supply|backplane|board|system)/) next
      n = int(val + 0)
      if (n > max) max=n
    }
    END{ if (max>=0) print max }' "$IPMI_CACHE"
}

# -------- % helpers --------
apply_delta() {
  # args: current_pct deltaC
  local cur="$1" dC="$2" next
  if (( dC > 0 )); then
    next=$(( cur + UP_GAIN * dC ))
  elif (( dC < 0 )); then
    dC=$(( -dC ))
    next=$(( cur - DOWN_GAIN * dC ))
  else
    next="$cur"
  fi
  (( next < MIN_PCT )) && next="$MIN_PCT"
  (( next > MAX_PCT )) && next="$MAX_PCT"
  echo "$next"
}

apply_slew() {
  # args: last_pct desired_pct
  local last="$1" want="$2"
  (( SLEW_PCT == 0 )) && { echo "$want"; return; }
  local delta=$(( want - last ))
  if   (( delta >  SLEW_PCT )); then echo $(( last + SLEW_PCT ))
  elif (( delta < -SLEW_PCT )); then echo $(( last - SLEW_PCT ))
  else echo "$want"; fi
}

# -------- IBM mapping (predefined step codes) --------
ibm_hex_for_pct() {
  local p=$1
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
}

# -------- Writers --------
set_ibm_bank() { local bank="$1" pct="$2" hx; hx="$(ibm_hex_for_pct "$pct")"; ipmitool raw 0x3a 0x07 "$bank" "$hx" 0x01; }
pct_to_hex()  { local p="$1"; (( p<0 )) && p=0; (( p>100 )) && p=100; printf "0x%02x" "$p"; }
set_dell_global() {
  local pct="$1" hx; hx="$(pct_to_hex "$pct")"
  ipmitool raw 0x30 0x30 0x01 0x00    # manual mode (idempotent)
  ipmitool raw 0x30 0x30 0x02 0xff "$hx"
}

# -------- State --------
VENDOR="$(detect_vendor)"
echo "Vendor: $VENDOR"

LAST_TEMP="$BASELINE_C"     # last hottest-CPU temperature (both vendors)
CUR_PCT="$MIN_PCT"          # current applied % (global or both IBM banks)

# Also track IBM CPU presence so we only touch existing banks
HAVE_CPU1=0; HAVE_CPU2=0

# -------- Main loop --------
while true; do
  if ! fetch_ipmi; then
    echo "IPMI read failed; retrying..."
    sleep "$INTERVAL"; continue
  fi

  if [[ "$VENDOR" == "ibm" ]]; then
    T1="$(get_temp_label_ibm "$CPU1_LABEL")"
    T2="$(get_temp_label_ibm "$CPU2_LABEL")"
    [[ -n "$T1" ]] && HAVE_CPU1=1
    [[ -n "$T2" ]] && HAVE_CPU2=1

    # pick hottest available CPU (same reactive logic as Dell)
    HOT=0
    [[ -n "$T1" && "$T1" -gt "$HOT" ]] && HOT="$T1"
    [[ -n "$T2" && "$T2" -gt "$HOT" ]] && HOT="$T2"

    if (( HOT == 0 )) && [[ -z "$T1" && -z "$T2" ]]; then
      echo "IBM: no CPU temps found; retrying..."
      sleep "$INTERVAL"; continue
    fi

    dC=$(( HOT - LAST_TEMP ))
    WANT="$(apply_delta "$CUR_PCT" "$dC")"
    CUR_PCT="$(apply_slew "$CUR_PCT" "$WANT")"

    # apply same % to whichever CPU banks actually exist
    [[ $HAVE_CPU1 -eq 1 ]] && set_ibm_bank "$IBM_BANK1" "$CUR_PCT"
    [[ $HAVE_CPU2 -eq 1 ]] && set_ibm_bank "$IBM_BANK2" "$CUR_PCT"

    LAST_TEMP="$HOT"
    echo "IBM: HOT=${HOT}°C  Δ=${dC}°C  -> ${CUR_PCT}% (banks: ${HAVE_CPU1:+1}${HAVE_CPU2:+2})"

  else
    HOT="$(get_hottest_temp_generic)"
    if [[ -z "$HOT" ]]; then
      echo "Dell/clone: no sensible temperature found; retrying..."
      sleep "$INTERVAL"; continue
    fi

    dC=$(( HOT - LAST_TEMP ))
    WANT="$(apply_delta "$CUR_PCT" "$dC")"
    CUR_PCT="$(apply_slew "$CUR_PCT" "$WANT")"
    set_dell_global "$CUR_PCT"
    LAST_TEMP="$HOT"
    echo "Dell/clone: HOT=${HOT}°C  Δ=${dC}°C  -> ${CUR_PCT}%"
  fi

  sleep "$INTERVAL"
done
