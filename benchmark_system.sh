#!/usr/bin/env bash
# Sysbench baseline: CPU, MEMORY, THREADS, MUTEX
# Single-file, no dependencies beyond: bash, sysbench, coreutils, awk, sed
# Usage:
#   sudo chmod +x sb-run.sh
#   ./sb-run.sh
#   ./sb-run.sh --duration 30 --repeats 3 --threads "1,2,4,8,16" --mem-block "4K" --mem-total "32G"
#
# Notes:
# - Works with sysbench 1.x (cpu, memory, threads, mutex)
# - Saves raw outputs and parsed summaries under results/<timestamp>/
# - JSON is lightweight (per-test metrics) for quick diffs / ingestion
# - No overreach: no tuning, no background daemons, no package installs

set -euo pipefail
IFS=$'\n\t'

# ---------- Defaults (change or override with CLI switches) ----------
DURATION=${DURATION:-10}                # seconds per run
REPEATS=${REPEATS:-1}                  # repeats per threads value
THREADS_LIST=${THREADS_LIST:-"1,2,4,8,16"}  # threads sweep
CPU_MAX_PRIME=${CPU_MAX_PRIME:-20000}  # sysbench cpu --cpu-max-prime
MEM_BLOCK=${MEM_BLOCK:-"4K"}           # sysbench memory --memory-block-size
MEM_TOTAL=${MEM_TOTAL:-"8G"}           # sysbench memory --memory-total-size
MEM_ACCESS=${MEM_ACCESS:-"seq"}        # seq|rnd
MEM_OPER=${MEM_OPER:-"read"}           # write|read  (sysbench counts writes as the operation; 'write' supported)
THREAD_YIELDS=${THREAD_YIELDS:-1000}   # sysbench threads --thread-yields
THREAD_LOCKS=${THREAD_LOCKS:-8}        # sysbench threads --thread-locks
MUTEX_NUM=${MUTEX_NUM:-4096}           # sysbench mutex --mutex-num
MUTEX_LOCKS=${MUTEX_LOCKS:-50000}      # sysbench mutex --mutex-locks
MUTEX_LOOPS=${MUTEX_LOOPS:-10000}      # sysbench mutex --mutex-loops
COOLDOWN=${COOLDOWN:-5}                # seconds between runs
OUTDIR_ROOT=${OUTDIR_ROOT:-"results"}
DATE_TAG=$(date +"%Y%m%d-%H%M%S")
OUTDIR="${OUTDIR_ROOT}/${DATE_TAG}"

# ---------- CLI parsing ----------
usage() {
  cat <<EOF
Usage: $0 [options]
  --duration <sec>         Per-run duration (default: ${DURATION})
  --repeats <n>            Repeats per thread count (default: ${REPEATS})
  --threads "a,b,c"        Threads matrix (default: ${THREADS_LIST})
  --cpu-max-prime <n>      cpu max prime (default: ${CPU_MAX_PRIME})
  --mem-block <size>       memory block size (default: ${MEM_BLOCK})
  --mem-total <size>       memory total size per run (default: ${MEM_TOTAL})
  --mem-access <seq|rnd>   memory access (default: ${MEM_ACCESS})
  --mem-oper <write|read>  memory oper (default: ${MEM_OPER})
  --thread-yields <n>      threads benchmark yields (default: ${THREAD_YIELDS})
  --thread-locks <n>       threads benchmark locks (default: ${THREAD_LOCKS})
  --mutex-num <n>          mutex num (default: ${MUTEX_NUM})
  --mutex-locks <n>        mutex locks (default: ${MUTEX_LOCKS})
  --mutex-loops <n>        mutex loops (default: ${MUTEX_LOOPS})
  --cooldown <sec>         sleep between runs (default: ${COOLDOWN})
  --outdir <dir>           results root (default: ${OUTDIR_ROOT})
  -h|--help                Show this help
Examples:
  $0
  $0 --duration 60 --repeats 3 --threads "1,2,4,8,16,32"
  $0 --mem-access rnd --mem-oper read --mem-total 16G
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration) DURATION="$2"; shift 2;;
    --repeats) REPEATS="$2"; shift 2;;
    --threads) THREADS_LIST="$2"; shift 2;;
    --cpu-max-prime) CPU_MAX_PRIME="$2"; shift 2;;
    --mem-block) MEM_BLOCK="$2"; shift 2;;
    --mem-total) MEM_TOTAL="$2"; shift 2;;
    --mem-access) MEM_ACCESS="$2"; shift 2;;
    --mem-oper) MEM_OPER="$2"; shift 2;;
    --thread-yields) THREAD_YIELDS="$2"; shift 2;;
    --thread-locks) THREAD_LOCKS="$2"; shift 2;;
    --mutex-num) MUTEX_NUM="$2"; shift 2;;
    --mutex-locks) MUTEX_LOCKS="$2"; shift 2;;
    --mutex-loops) MUTEX_LOOPS="$2"; shift 2;;
    --cooldown) COOLDOWN="$2"; shift 2;;
    --outdir) OUTDIR_ROOT="$2"; OUTDIR="${OUTDIR_ROOT}/${DATE_TAG}"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1"; usage; exit 1;;
  esac
done

# ---------- Preflight ----------
command -v sysbench >/dev/null 2>&1 || { echo "ERROR: sysbench not found in PATH."; exit 1; }
mkdir -p "${OUTDIR}"/{raw,sysinfo}
SUMMARY_CSV="${OUTDIR}/summary.csv"
SUMMARY_JSON="${OUTDIR}/summary.json"

echo "== sysbench baseline =="
echo "Output directory: ${OUTDIR}"
echo "Threads matrix: ${THREADS_LIST}"
echo "Duration: ${DURATION}s, Repeats: ${REPEATS}"
echo

# ---------- System info snapshot (non-root friendly) ----------
{
  echo "# Timestamp: $(date -Is)"
  echo "# Host: $(hostname -f 2>/dev/null || hostname)"
  echo "---- uname -a ----"
  uname -a || true
  echo "---- lscpu ----"
  lscpu || true
  echo "---- numactl --hardware ----"
  numactl --hardware || true
  echo "---- free -h ----"
  free -h || true
  echo "---- /proc/meminfo (top) ----"
  head -n 20 /proc/meminfo || true
} > "${OUTDIR}/sysinfo/host.txt"

# (Optional deeper info – skipped if no perms)
if [[ $EUID -eq 0 ]]; then
  dmidecode -t memory > "${OUTDIR}/sysinfo/dmidecode_memory.txt" 2>/dev/null || true
fi

# ---------- Helpers: append CSV/JSON safely ----------
init_csv() {
  echo "timestamp,test,threads,repeat,events_per_sec,avg_ms,p95_ms,throughput_mb_s,notes" > "${SUMMARY_CSV}"
}
init_json() {
  echo '{"runs": []}' > "${SUMMARY_JSON}"
}
append_csv() {
  # $1 timestamp, $2 test, $3 threads, $4 repeat, $5 eps, $6 avg_ms, $7 p95_ms, $8 mbps, $9 notes
  echo "$1,$2,$3,$4,$5,$6,$7,$8,$9" >> "${SUMMARY_CSV}"
}
append_json() {
  # naive JSON append (valid for our simple array)
  local ts="$1" test="$2" thr="$3" rep="$4" eps="$5" avg="$6" p95="$7" mbps="$8" notes="$9"
  # Use awk to inject an element into the 'runs' array
  awk -v ts="$ts" -v test="$test" -v thr="$thr" -v rep="$rep" -v eps="$eps" -v avg="$avg" -v p95="$p95" -v mbps="$mbps" -v notes="$notes" '
    BEGIN { RS=""; FS=""; }
    {
      sub(/\}$/, "", $0);
      if ($0 ~ /\[\]$/) {
        sub(/\[\]$/, "[\n]", $0);
      }
      if ($0 ~ /"runs": \[\n\]$/) {
        sub(/\[\n\]$/, "[\n]", $0);
      }
      print $0 ",\n  {\"timestamp\":\"" ts "\",\"test\":\"" test "\",\"threads\":" thr ",\"repeat\":" rep ",\"events_per_sec\":" eps ",\"avg_ms\":" avg ",\"p95_ms\":" p95 ",\"throughput_mb_s\":" mbps ",\"notes\":\"" notes "\"}\n] }";
    }
  ' "${SUMMARY_JSON}" > "${SUMMARY_JSON}.tmp" && mv "${SUMMARY_JSON}.tmp" "${SUMMARY_JSON}"
}

init_csv
init_json

# ---------- Parse helpers (robust across sysbench versions) ----------
parse_eps() { # events per second
  # grep both "events per second" and "events/s"
  awk -F':' '/events per second/ {gsub(/^[ \t]+/,"",$2); print $2}
             /events\/s/ {print $3}' "$1" | head -n1 | tr -d ' ' || true
}
parse_avg_ms() { # avg latency ms
  # look for "avg:" under "Latency (ms)"
  awk '/Latency .*ms/ {f=1} f && /avg/ {gsub(/[^0-9\.\-]/,""); print $0; exit}' "$1" || true
}
parse_p95_ms() {
  awk '/Latency .*ms/ {f=1} f && /95th percentile/ {gsub(/[^0-9\.\-]/,""); print $0; exit}' "$1" || true
}
parse_mb_s() { # memory throughput MB/s line: "transferred (X.Y MB/sec)"
  awk -F'[()]' '/transferred/ { split($2,a," "); for (i=1;i<=NF;i++) if ($2 ~ /MB\/sec/) {print a[1]; exit} }' "$1" || true
}

# ---------- Runner ----------
run_cpu() {
  local t="$1" r="$2" ts note eps avg p95
  ts=$(date -Is)
  local of="raw/cpu_t${t}_r${r}.txt"
  note="cpu-max-prime=${CPU_MAX_PRIME};duration=${DURATION}"
  sysbench cpu --threads="${t}" --time="${DURATION}" --cpu-max-prime="${CPU_MAX_PRIME}" run | tee "${OUTDIR}/${of}" >/dev/null
  eps=$(parse_eps "${OUTDIR}/${of}")
  avg=$(parse_avg_ms "${OUTDIR}/${of}")
  p95=$(parse_p95_ms "${OUTDIR}/${of}")
  append_csv "${ts}" "cpu" "${t}" "${r}" "${eps:-}" "${avg:-}" "${p95:-}" "" "${note}"
  append_json "${ts}" "cpu" "${t}" "${r}" "${eps:-0}" "${avg:-0}" "${p95:-0}" "0" "${note}"
}

run_memory() {
  local t="$1" r="$2" ts note eps avg p95 mbps
  ts=$(date -Is)
  local of="raw/mem_t${t}_r${r}.txt"
  note="block=${MEM_BLOCK};total=${MEM_TOTAL};access=${MEM_ACCESS};oper=${MEM_OPER};duration=${DURATION}"
  sysbench memory --threads="${t}" --time="${DURATION}" \
    --memory-block-size="${MEM_BLOCK}" --memory-total-size="${MEM_TOTAL}" \
    --memory-access-mode="${MEM_ACCESS}" --memory-oper="${MEM_OPER}" run | tee "${OUTDIR}/${of}" >/dev/null
  eps=$(parse_eps "${OUTDIR}/${of}")        # not always present for memory; keep if emitted
  avg=$(parse_avg_ms "${OUTDIR}/${of}")     # may be blank
  p95=$(parse_p95_ms "${OUTDIR}/${of}")     # may be blank
  mbps=$(parse_mb_s "${OUTDIR}/${of}")
  append_csv "${ts}" "memory" "${t}" "${r}" "${eps:-}" "${avg:-}" "${p95:-}" "${mbps:-}" "${note}"
  append_json "${ts}" "memory" "${t}" "${r}" "${eps:-0}" "${avg:-0}" "${p95:-0}" "${mbps:-0}" "${note}"
}

run_threads() {
  local t="$1" r="$2" ts note eps avg p95
  ts=$(date -Is)
  local of="raw/threads_t${t}_r${r}.txt"
  note="yields=${THREAD_YIELDS};locks=${THREAD_LOCKS};duration=${DURATION}"
  sysbench threads --threads="${t}" --time="${DURATION}" \
    --thread-yields="${THREAD_YIELDS}" --thread-locks="${THREAD_LOCKS}" run | tee "${OUTDIR}/${of}" >/dev/null
  eps=$(parse_eps "${OUTDIR}/${of}")
  avg=$(parse_avg_ms "${OUTDIR}/${of}")
  p95=$(parse_p95_ms "${OUTDIR}/${of}")
  append_csv "${ts}" "threads" "${t}" "${r}" "${eps:-}" "${avg:-}" "${p95:-}" "" "${note}"
  append_json "${ts}" "threads" "${t}" "${r}" "${eps:-0}" "${avg:-0}" "${p95:-0}" "0" "${note}"
}

run_mutex() {
  local t="$1" r="$2" ts note eps avg p95
  ts=$(date -Is)
  local of="raw/mutex_t${t}_r${r}.txt"
  note="mutex-num=${MUTEX_NUM};locks=${MUTEX_LOCKS};loops=${MUTEX_LOOPS};duration=${DURATION}"
  sysbench mutex --threads="${t}" --time="${DURATION}" \
    --mutex-num="${MUTEX_NUM}" --mutex-locks="${MUTEX_LOCKS}" --mutex-loops="${MUTEX_LOOPS}" run | tee "${OUTDIR}/${of}" >/dev/null
  eps=$(parse_eps "${OUTDIR}/${of}")
  avg=$(parse_avg_ms "${OUTDIR}/${of}")
  p95=$(parse_p95_ms "${OUTDIR}/${of}")
  append_csv "${ts}" "mutex" "${t}" "${r}" "${eps:-}" "${avg:-}" "${p95:-}" "" "${note}"
  append_json "${ts}" "mutex" "${t}" "${r}" "${eps:-0}" "${avg:-0}" "${p95:-0}" "0" "${note}"
}

# ---------- Main sweep ----------
echo "Collecting baselines into: ${OUTDIR}"
echo "------------------------------------------"
echo "System info written to: ${OUTDIR}/sysinfo/"
echo "Raw logs to:            ${OUTDIR}/raw/"
echo "Summary CSV:            ${SUMMARY_CSV}"
echo "Summary JSON:           ${SUMMARY_JSON}"
echo "------------------------------------------"

IFS=',' read -r -a THREAD_ARR <<< "${THREADS_LIST}"

for t in "${THREAD_ARR[@]}"; do
  for (( r=1; r<=REPEATS; r++ )); do
    echo "[CPU   ] threads=${t} repeat=${r}/${REPEATS}"
    run_cpu "${t}" "${r}"
    sleep "${COOLDOWN}"

    echo "[MEM   ] threads=${t} repeat=${r}/${REPEATS}"
    run_memory "${t}" "${r}"
    sleep "${COOLDOWN}"

    echo "[THREAD] threads=${t} repeat=${r}/${REPEATS}"
    run_threads "${t}" "${r}"
    sleep "${COOLDOWN}"

    echo "[MUTEX ] threads=${t} repeat=${r}/${REPEATS}"
    run_mutex "${t}" "${r}"
    sleep "${COOLDOWN}"
  done
done

echo "------------------------------------------"
echo "Done. Results under ${OUTDIR}"
