#!/usr/bin/env bash
set -euo pipefail

# LAN Auto-Tuner (local-only, run as root on CLIENT)
# - Tunes LOCAL NICs only (no remote sudo)
# - Benchmarks vs SERVER (iperf3 by default)
# - Can auto-start/stop iperf3 server on SERVER (SSH, no sudo there)

SERVER_HOST=""
SSH_USER=""              # optional SSH user for server
IFACES="auto"
BOND_IF=""
BENCH_CMD=""             # default iperf3 client
AUTO_SERVER=1
IPERF_PORT="5201"
IPERF_TIME="10"
IPERF_PARALLEL="4"

RX_QUEUES_CANDIDATES=("1" "2" "4")
RING_RX_CANDIDATES=("512" "1024")
RING_TX_CANDIDATES=("256" "512")
COAL_USEC_CANDIDATES=("4" "8" "12")
OFFLOAD_PROFILES=("gro:on,gso:on,tso:on" "gro:on,gso:on,tso:off")

SYSCTLS=("net.core.default_qdisc=fq" "net.ipv4.tcp_congestion_control=bbr" "net.core.netdev_max_backlog=1000")

RPS_MASKS_RAW=""
XPS_FOLLOWS_RPS=1
IRQBALANCE_MODE="leave"  # leave|disable|enable
MTU="1500"
DURATION_HINT="5s"
OUTDIR="./lan-autotune-logs/$(date +%Y%m%d-%H%M%S)"

PATH_SBIN='/usr/local/sbin:/usr/sbin:/sbin'
export PATH="$PATH:$PATH_SBIN"

die(){ echo "Error: $*" >&2; exit 1; }
info(){ echo "[*] $*"; }
ensure_dir(){ mkdir -p "$OUTDIR"; }

usage(){
  cat <<EOF
Usage (run as root on CLIENT):
  $(basename "$0") --server <host> [options]

Options:
  --server <host>              ip/hostname of server endpoint
  --ssh-user <name>            SSH user for server (default: invoking user, not root)
  --ifaces auto|csv            Local ifaces to tune (default: auto)
  --bond <name>                Optional bond master (e.g. bond0)
  --mtu <n>                    MTU to enforce locally (default 1500)
  --irqbalance leave|disable|enable (default leave)
  --bench "<cmd>"              Custom bench on CLIENT; default iperf3 client
  --no-auto-server             Do not start/stop iperf3 server on remote
  --iperf-port <n>             (default 5201)
  --iperf-time <s>             (default 10)
  --iperf-parallel <n>         (default 4)
  --rps-masks "m0[,m1...]"     Hex CPU masks per iface; auto if omitted
  --duration <secs>            Sleep between trials (default 5s)
EOF
}

# -------- parse args --------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --server) SERVER_HOST="$2"; shift 2;;
    --ssh-user) SSH_USER="$2"; shift 2;;
    --ifaces) IFACES="$2"; shift 2;;
    --bond) BOND_IF="$2"; shift 2;;
    --mtu) MTU="$2"; shift 2;;
    --irqbalance) IRQBALANCE_MODE="$2"; shift 2;;
    --bench) BENCH_CMD="$2"; shift 2;;
    --no-auto-server) AUTO_SERVER=0; shift;;
    --iperf-port) IPERF_PORT="$2"; shift 2;;
    --iperf-time) IPERF_TIME="$2"; shift 2;;
    --iperf-parallel) IPERF_PARALLEL="$2"; shift 2;;
    --rps-masks) RPS_MASKS_RAW="$2"; shift 2;;
    --duration) DURATION_HINT="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) die "Unknown arg: $1";;
  esac
done

# -------- root / deps --------
[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run this script as root on the CLIENT."
[[ -n "$SERVER_HOST" ]] || die "--server is required"

need(){ command -v "$1" >/dev/null 2>&1 || die "Missing: $1"; }
need ip; need ethtool; need sysctl; need ssh; need awk; need sed; need grep

bench_is_iperf=0
if [[ -z "$BENCH_CMD" || "$BENCH_CMD" =~ ^iperf3 ]]; then
  bench_is_iperf=1; need iperf3
else
  first_word="$(awk '{print $1}' <<<"$BENCH_CMD")"; need "$first_word"
fi

ensure_dir
echo "server=$SERVER_HOST" > "$OUTDIR/context.txt"
echo "ssh_user=${SSH_USER:-<default-invoking-user>}" >> "$OUTDIR/context.txt"
echo "bond=$BOND_IF" >> "$OUTDIR/context.txt"
echo "bench=${BENCH_CMD:-<auto iperf3>}" >> "$OUTDIR/context.txt"

# -------- helpers --------
ssh_server(){
  local who="${SSH_USER:-$(logname 2>/dev/null || id -un)}"
  ssh -o BatchMode=no -o StrictHostKeyChecking=accept-new "${who}@${SERVER_HOST}" "$@"
}

find_ifaces_auto(){
  if ls /proc/net/bonding >/dev/null 2>&1 && [ -n "$(ls -A /proc/net/bonding)" ]; then
    awk '/Slave Interface:/{print $3}' /proc/net/bonding/* 2>/dev/null | sort -u
  else
    ls -1 /sys/class/net \
      | grep -Ev '^(lo|veth|docker|br-|virbr|vmnet|tap|wg|tailscale|sit|ib|bonding_masters)$'
  fi
}

derive_masks(){
  local count="$1"
  if [[ -n "$RPS_MASKS_RAW" ]]; then echo "$RPS_MASKS_RAW"; return; fi
  local n="$(nproc)"; (( n<2 )) && { printf "0x1"; return; }
  local half=$((n/2)); local m1=0 m2=0
  for ((c=0;c<half;c++)); do m1=$((m1 | (1<<c))); done
  for ((c=half;c<n;c++));  do m2=$((m2 | (1<<c))); done
  local a=("$(printf "0x%x" "$m1")" "$(printf "0x%x" "$m2")")
  local out=""; for ((i=0;i<count;i++)); do [[ -n "$out" ]] && out+=','; out+="${a[i % ${#a[@]}]}"; done
  echo "$out"
}

apply_mtu_local(){
  local mtu="$1" bond="$2"; shift 2; local ifs=("$@")
  echo "[MTU] Current:"; ip -o link show | awk '{dev=$2; sub(/:$/,"",dev); if (match($0,/mtu ([0-9]+)/,a)) print dev, a[1]}'
  if [[ -n "$bond" && -e "/sys/class/net/$bond" ]]; then
    local cur="$(ip -o link show dev "$bond" | awk 'match($0,/mtu ([0-9]+)/,a){print a[1]}')"
    if [[ "$cur" != "$mtu" ]]; then echo "[MTU] $bond: $cur -> $mtu"; ip link set dev "$bond" mtu "$mtu" || true
    else echo "[MTU] $bond already $mtu"; fi
  fi
  for i in "${ifs[@]}"; do
    [[ -e "/sys/class/net/$i" ]] || { echo "[MTU] WARN: $i not found"; continue; }
    local cur="$(ip -o link show dev "$i" | awk 'match($0,/mtu ([0-9]+)/,a){print a[1]}')"
    if [[ "$cur" != "$mtu" ]]; then echo "[MTU] $i: $cur -> $mtu"; ip link set dev "$i" mtu "$mtu" || true
    else echo "[MTU] $i already $mtu"; fi
  done
  echo "[MTU] After:"; ip -o link show | awk '{dev=$2; sub(/:$/,"",dev); if (match($0,/mtu ([0-9]+)/,a)) print dev, a[1]}'
}

set_irqbalance_local(){
  case "$IRQBALANCE_MODE" in
    leave)  info "irqbalance unchanged";;
    disable) info "irqbalance disable"; systemctl disable --now irqbalance >/dev/null 2>&1 || true;;
    enable)  info "irqbalance enable";  systemctl enable  --now irqbalance >/dev/null 2>&1 || true;;
  esac
}

apply_sysctls_local(){ for s in "${SYSCTLS[@]}"; do sysctl -w "$s"; done; }

set_rps_xps_local(){
  local masks_csv; masks_csv="$(derive_masks "$#")"
  IFS=',' read -r -a masks <<< "$masks_csv"
  local idx=0
  for ifc in "$@"; do
    local mask="${masks[$idx]:-0x1}"; idx=$((idx+1))
    shopt -s nullglob
    local rxqs=(/sys/class/net/"$ifc"/queues/rx-*)
    if ((${#rxqs[@]})); then
      for Q in "${rxqs[@]}"; do
        echo "$mask"  > "$Q/rps_cpus"     2>/dev/null || true
        echo 2048     > "$Q/rps_flow_cnt" 2>/dev/null || true
      done
    else
      echo "[RPS] WARN: no rx-* queues for $ifc"
    fi
    if (( XPS_FOLLOWS_RPS )); then
      local txqs=(/sys/class/net/"$ifc"/queues/tx-*)
      for Q in "${txqs[@]}"; do
        echo "$mask" > "$Q/xps_cpus" 2>/dev/null || true
      done
    fi
  done
}

apply_combo_local(){
  local rxq="$1" ring_rx="$2" ring_tx="$3" coal="$4" off_csv="$5"; shift 5; local ifs=("$@")
  for ifc in "${ifs[@]}"; do
    ethtool -L "$ifc" rx "$rxq"    >/dev/null 2>&1 || true
    ethtool -G "$ifc" rx "$ring_rx" tx "$ring_tx" >/dev/null 2>&1 || true
    ethtool -C "$ifc" rx-usecs "$coal" tx-usecs "$coal" >/dev/null 2>&1 || true
    IFS=',' read -r -a pairs <<< "$off_csv"
    for p in "${pairs[@]}"; do
      local k="${p%%:*}" v="${p##*:}"
      ethtool -K "$ifc" "$k" "$v" >/dev/null 2>&1 || true
    done
  done
}

snapshot_before_local(){
  local ifs=("$@"); local ts="$OUTDIR/before.txt"; : > "$ts"
  for ifc in "${ifs[@]}"; do
    {
      echo "### $ifc"
      (ethtool -l "$ifc" || true)
      (ethtool -g "$ifc" || true)
      (ethtool -C "$ifc" || true)
      (ethtool -k "$ifc" || true)
    } >> "$ts" 2>/dev/null || true
  done
}

# --- safe revert builder ---
build_revert_local(){
  local ifs=("$@"); local rev="$OUTDIR/revert.sh"; : > "$rev"
  {
    echo "#!/usr/bin/env bash"
    echo "set -euo pipefail"
    for ifc in "${ifs[@]}"; do
      echo "# $ifc"
      local block; block="$(awk "/^### $ifc\$/{f=1;next}/^### /{f=0} f" "$OUTDIR/before.txt" || true)"

      # RX channel count
      local rxch; rxch="$(printf '%s\n' "$block" | awk '/Channel parameters/{f=1;next} f&&/^RX:/{print $2; exit}' || true)"
      [[ -n "${rxch:-}" ]] && echo "ethtool -L $ifc rx $rxch || true"

      # Rings
      local rings; rings="$(printf '%s\n' "$block" | awk '/Ring parameters/{f=1;next} f' || true)"
      local rxring; rxring="$(printf '%s\n' "$rings" | awk '/^RX:/{print $2; exit}' || true)"
      local txring; txring="$(printf '%s\n' "$rings" | awk '/^TX:/{print $2; exit}' || true)"
      [[ -n "${rxring:-}" && -n "${txring:-}" ]] && echo "ethtool -G $ifc rx $rxring tx $txring || true"

      # Coalescing
      local rxc txc
      rxc="$(printf '%s\n' "$block" | grep -E '^rx-usecs:' | head -n1 | cut -d':' -f2 | tr -d ' ' || true)"
      txc="$(printf '%s\n' "$block" | grep -E '^tx-usecs:' | head -n1 | cut -d':' -f2 | tr -d ' ' || true)"
      [[ -n "${rxc:-}" && -n "${txc:-}" ]] && echo "ethtool -C $ifc rx-usecs $rxc tx-usecs $txc || true"

      # Features
      printf '%s\n' "$block" | awk '/Features for/{f=1;next} f' | \
        awk '{print $1,$2}' | sed 's/:$//' | while read -r feat state; do
          case "$state" in on|off) echo "ethtool -K $ifc $feat $state || true";; esac
        done
    done
  } >> "$rev"
  chmod +x "$rev"
  echo "[*] Revert script: $rev"
}

# -------- iperf3 auto server (remote, no sudo) --------
iperf_started=0
ensure_iperf_server(){
  (( bench_is_iperf )) || return 0
  (( AUTO_SERVER )) || return 0
  if ssh_server "ss -ltn sport = :$IPERF_PORT | grep -q LISTEN" >/dev/null 2>&1; then
    info "iperf3 server already listening on $SERVER_HOST:$IPERF_PORT"; return 0
  fi
  info "Starting iperf3 server on $SERVER_HOST:$IPERF_PORT"
  if ! ssh_server "nohup iperf3 -s -p $IPERF_PORT >/tmp/iperf3-server.log 2>&1 & disown"; then
    echo "WARN: could not start iperf3 server via SSH. You can:"
    echo "  - run: ssh ${SSH_USER:-$(logname 2>/dev/null || id -un)}@${SERVER_HOST} 'iperf3 -s -p $IPERF_PORT'"
    echo "  - or rerun with --no-auto-server"
    return 0
  fi
  for _ in {1..10}; do
    ssh_server "ss -ltn sport = :$IPERF_PORT | grep -q LISTEN" >/dev/null 2>&1 && { iperf_started=1; return 0; }
    sleep 0.5
  done
  echo "WARN: Could not confirm iperf3 server is listening (continuing)."
}
stop_iperf_server(){
  (( bench_is_iperf )) || return 0
  (( AUTO_SERVER )) || return 0
  (( iperf_started )) || return 0
  info "Stopping iperf3 server on $SERVER_HOST"
  ssh_server "pkill -f '^iperf3 -s' || true" || true
}
trap 'stop_iperf_server' EXIT

# -------- plan --------
plan_file="$OUTDIR/plan.txt"; : > "$plan_file"
for q in "${RX_QUEUES_CANDIDATES[@]}"; do
  for rx in "${RING_RX_CANDIDATES[@]}"; do
    for tx in "${RING_TX_CANDIDATES[@]}"; do
      for u in "${COAL_USEC_CANDIDATES[@]}"; do
        for off in "${OFFLOAD_PROFILES[@]}"; do
          echo "RXQ=$q RING_RX=$rx RING_TX=$tx COAL=$u OFF={$off}" >> "$plan_file"
        done
      done
    done
  done
done
info "Planned combinations: $(wc -l < "$plan_file")"

# -------- iface discovery --------
IFS=',' read -r -a IF_ARR <<< "$IFACES"
if [[ "$IFACES" == "auto" ]]; then
  mapfile -t IF_ARR < <(find_ifaces_auto)
  [[ "${#IF_ARR[@]}" -gt 0 ]] || die "Auto-detect found no tunable local interfaces"
fi
echo "ifaces=${IF_ARR[*]}" >> "$OUTDIR/context.txt"

# -------- prep (LOCAL) --------
info "Detecting NIC caps locally..."
for ifc in "${IF_ARR[@]}"; do
  info "Caps for $ifc"
  (ethtool -l "$ifc" || true); (ethtool -g "$ifc" || true)
done

set_irqbalance_local
apply_mtu_local "$MTU" "$BOND_IF" "${IF_ARR[@]}"
if [[ -n "$BOND_IF" && -e "/sys/class/net/$BOND_IF/bonding/xmit_hash_policy" ]]; then
  echo layer3+4 > "/sys/class/net/$BOND_IF/bonding/xmit_hash_policy" || true
fi
apply_sysctls_local
set_rps_xps_local "${IF_ARR[@]}"

snapshot_before_local "${IF_ARR[@]}"
build_revert_local   "${IF_ARR[@]}"

# -------- bench cmd --------
bench_cmd_resolved="$BENCH_CMD"
if (( bench_is_iperf )); then
  iperf_bin="$(command -v iperf3 || true)"
  [[ -n "$iperf_bin" ]] || die "iperf3 not found in PATH"
  ensure_iperf_server
  bench_cmd_resolved="iperf3 -J -c $SERVER_HOST -p $IPERF_PORT -t $IPERF_TIME -P $IPERF_PARALLEL -i 1"
fi
info "Benchmark cmd: $bench_cmd_resolved"

# -------- results --------
results_csv="$OUTDIR/results.csv"
echo "rxq,ring_rx,ring_tx,coal,offloads,p50_ms,p99_ms,rps,mbps" > "$results_csv"

# ---- robust metrics parser ----
parse_metrics(){
  local raw; raw="$(cat)"

  # --- iperf3 JSON (TCP) ─ throughput + RTT percentiles ---
  if grep -q '"end"' <<<"$raw" && grep -q '"sum_received"' <<<"$raw"; then
    # 1) Mbps via jq (preferred), with awk fallback
    local bps mbps
    if command -v jq >/dev/null 2>&1; then
      bps="$(jq -r '(.end.sum_received.bits_per_second // .end.sum.bits_per_second // 0)' 2>/dev/null <<<"$raw")"
      [[ "$bps" =~ ^[0-9]+(\.[0-9]+)?$ ]] || bps=0
    else
      # very defensive awk: take the first bits_per_second under sum(_received)
      bps="$(awk '
        /"sum_received"[[:space:]]*:/ { sr=1 }
        sr && /"bits_per_second"[[:space:]]*:/ {
          gsub(/[^0-9.]/,"",$0); print $0; exit
        }' <<<"$raw")"
      [[ "$bps" =~ ^[0-9]+(\.[0-9]+)?$ ]] || bps=0
    fi
    mbps="$(awk -v b="$bps" 'BEGIN{printf("%.2f", b/1000000)}')"

    # 2) Collect all RTTs (µs) → ms. Try jq first; if empty, grep fallback.
    local rtts
    if command -v jq >/dev/null 2>&1; then
      rtts="$(jq -r '[.intervals[].streams[].rtt] | map(select(type=="number")) | .[]?' 2>/dev/null <<<"$raw")"
    fi
    # Fallback if jq missing OR returned nothing
    if [[ -z "$rtts" ]]; then
      rtts="$(grep -oE '"rtt"[[:space:]]*:[[:space:]]*[0-9]+' <<<"$raw" | awk -F: '{gsub(/ /,"",$2);print $2}')"
    fi

    # If we still have nothing, set zeros; else compute p50/p99
    local p50_ms="0.00" p99_ms="0.00"
    if [[ -n "$rtts" ]]; then
      # to ms with 2 decimals, sort, pick percentiles
      # Use awk to convert + sort -n + percentile index
      # median index = ceil(0.50*N), p99 index = ceil(0.99*N), 1-based
      read -r p50_ms p99_ms < <(
        awk '
          { v = $1/1000.0; printf("%.6f\n", v) }' <<<"$rtts" \
        | sort -n \
        | awk '{
            a[++n]=$1
          }
          END{
            if(n==0){ print "0.00 0.00"; exit }
            idx50 = int((0.50*n)+0.9999); if(idx50<1) idx50=1; if(idx50>n) idx50=n
            idx99 = int((0.99*n)+0.9999); if(idx99<1) idx99=1; if(idx99>n) idx99=n
            printf("%.2f %.2f", a[idx50], a[idx99])
          }'
      )
    fi

    echo "p50_ms=${p50_ms} p99_ms=${p99_ms} rps=0 mbps=${mbps}"
    return
  fi

  # --- wrk ---
  if grep -q "Requests/sec" <<<"$raw"; then
    local p50 p99 rps
    p50=$(grep -E "Latency[[:space:]]+[0-9.]+(ms|s)" <<<"$raw" | head -1 | awk '{print $2}')
    p99=$(grep -E " 99%[[:space:]]+[0-9.]+(ms|s)" <<<"$raw" | awk '{print $2}')
    rps=$(grep -E "Requests/sec:" <<<"$raw" | awk '{print $2}')
    to_ms(){ awk '{v=$1;u=substr($1,length($1)); if(u=="s"){printf("%.2f", v*1000)} else {printf("%.2f", v)}}' <<<"$1"; }
    echo "p50_ms=$(to_ms ${p50:-9999}) p99_ms=$(to_ms ${p99:-99999}) rps=${rps:-0} mbps=0"; return
  fi

  # --- hey ---
  if grep -q "^Requests/sec:" <<<"$raw"; then
    local rps p99; rps=$(grep -E "^Requests/sec:" <<<"$raw" | awk '{print $2}')
    p99=$(grep -E "^  99%" <<<"$raw" | awk '{print $2}')
    echo "p50_ms=0 p99_ms=${p99:-99999} rps=${rps:-0} mbps=0"; return
  fi

  # --- h2load ---
  if grep -q "requests:.*min" <<<"$raw"; then
    local p99 rps
    p99=$(grep -E "requests:.*99%" <<<"$raw" | awk '{print $6}' | sed 's/ms//')
    rps=$(grep -E "requests:.*/sec" <<<"$raw" | awk -F'/' '{print $2}' | sed 's/\/sec//;s/ //g')
    echo "p50_ms=0 p99_ms=${p99:-99999} rps=${rps:-0} mbps=0"; return
  fi

  echo "p50_ms=0 p99_ms=999999 rps=0 mbps=0"
}

combo_n=0
while read -r line; do
  [[ -z "$line" ]] && continue
  RXQ="$(awk '{for(i=1;i<=NF;i++) if($i ~ /^RXQ=/){split($i,a,"="); print a[2]}}' <<<"$line")"
  RING_RX="$(awk '{for(i=1;i<=NF;i++) if($i ~ /^RING_RX=/){split($i,a,"="); print a[2]}}' <<<"$line")"
  RING_TX="$(awk '{for(i=1;i<=NF;i++) if($i ~ /^RING_TX=/){split($i,a,"="); print a[2]}}' <<<"$line")"
  COAL="$(awk '{for(i=1;i<=NF;i++) if($i ~ /^COAL=/){split($i,a,"="); print a[2]}}' <<<"$line")"
  OFF="$(awk -F'OFF=\\{|\\}' '{print $2}' <<<"$line")"
  combo_n=$((combo_n+1))
  info "[$combo_n] Apply RXQ=$RXQ RING_RX=$RING_RX RING_TX=$RING_TX COAL=$COAL OFF={$OFF}"

  apply_combo_local "$RXQ" "$RING_RX" "$RING_TX" "$COAL" "$OFF" "${IF_ARR[@]}"

  trial_out="$OUTDIR/bench_${combo_n}.out"

  # Run bench with debug; capture rc
  echo "[DEBUG] running: $bench_cmd_resolved" | tee -a "$trial_out"
  raw="$($bench_cmd_resolved 2>&1)"
  rc=$?
  printf "%s\n" "$raw" >> "$trial_out"
  if (( rc != 0 )); then
    echo "[WARN] bench command exited with rc=$rc for combo #$combo_n" | tee -a "$trial_out"
  fi

  metrics="$(printf "%s" "$raw" | parse_metrics)"
  eval "$metrics"

  if (( bench_is_iperf )) && [[ "$mbps" == "0.00" ]]; then
    echo "[HINT] iperf3 JSON not detected for combo #$combo_n; check $trial_out" | tee -a "$trial_out"
  fi

  echo "$RXQ,$RING_RX,$RING_TX,$COAL,\"{$OFF}\",$p50_ms,$p99_ms,$rps,$mbps" >> "$results_csv"
  sleep "$DURATION_HINT"
done < "$plan_file"

best_csv="$OUTDIR/best.csv"
if (( bench_is_iperf )); then
  { head -n1 "$results_csv"; tail -n +2 "$results_csv" | sort -t, -k9,9nr -k7,7n; } | head -n 2 | tail -n 1 > "$best_csv"
else
  { head -n1 "$results_csv"; tail -n +2 "$results_csv" | sort -t, -k7,7n -k8,8nr; } | head -n 2 | tail -n 1 > "$best_csv"
fi

best_line="$(cat "$best_csv" || true)"
info "Best row: ${best_line:-<none>}"
echo "Logs in: $OUTDIR"
