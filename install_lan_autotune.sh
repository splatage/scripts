#!/usr/bin/env bash
set -euo pipefail

# install-nic-tune.sh
# Installs a systemd service that applies fixed NIC settings at boot.

### --- Config you can edit ---
IFACES=("eno1" "eno2" "eno3" "eno4")   # interfaces to tune
RXQ=4
RING_RX=512
RING_TX=512
COAL=4
OFFLOADS=("gro:on" "gso:on" "tso:on")
### ----------------------------

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1" >&2; exit 1; }; }

main() {
  # Require root
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "Please run as root (sudo $0)"; exit 1
  fi

  need ethtool
  need systemctl

  # Validate interfaces exist (warn if not)
  local present=0
  for i in "${IFACES[@]}"; do
    if [[ -e "/sys/class/net/$i" ]]; then
      present=1
    else
      echo "WARN: interface '$i' not found on this host" >&2
    fi
  done
  [[ $present -eq 1 ]] || { echo "No listed interfaces exist. Edit IFACES and retry." >&2; exit 1; }

  # Create /usr/local/bin/nic-tune.sh
  cat >/usr/local/bin/nic-tune.sh <<'EOS'
#!/usr/bin/env bash
set -euo pipefail

# This script is executed at boot by systemd to set NIC parameters.

# Keep this in sync with the installer’s config
IFACES=("eno1" "eno2" "eno3" "eno4")
RXQ=4
RING_RX=512
RING_TX=512
COAL=4
OFFLOADS=("gro:on" "gso:on" "tso:on")

log(){ echo "[nic-tune] $*"; }

apply_iface() {
  local ifc="$1"
  # Apply queue count (RX only)
  ethtool -L "$ifc" rx "$RXQ" >/dev/null 2>&1 || log "ethtool -L not supported on $ifc (ok)"
  # Apply ring sizes
  ethtool -G "$ifc" rx "$RING_RX" tx "$RING_TX" >/dev/null 2>&1 || log "ethtool -G not supported on $ifc (ok)"
  # Apply coalescing
  ethtool -C "$ifc" rx-usecs "$COAL" tx-usecs "$COAL" >/dev/null 2>&1 || log "ethtool -C not supported on $ifc (ok)"
  # Apply offloads
  for kv in "${OFFLOADS[@]}"; do
    k="${kv%%:*}"; v="${kv##*:}"
    ethtool -K "$ifc" "$k" "$v" >/dev/null 2>&1 || log "feature $k not supported on $ifc (ok)"
  done
}

for ifc in "${IFACES[@]}"; do
  if [[ -e "/sys/class/net/$ifc" ]]; then
    log "Tuning $ifc -> RXQ=$RXQ RING rx/tx=$RING_RX/$RING_TX COAL=$COAL OFFLOADS=${OFFLOADS[*]}"
    apply_iface "$ifc"
  else
    log "Skip $ifc (not present)"
  fi
done

exit 0
EOS

  chmod +x /usr/local/bin/nic-tune.sh

  # Create systemd unit
  cat >/etc/systemd/system/nic-tune.service <<'EOS'
[Unit]
Description=NIC tuning at boot
After=network.target
Wants=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/nic-tune.sh
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOS

  # Reload, enable, start
  systemctl daemon-reload
  systemctl enable nic-tune.service
  systemctl start nic-tune.service

  echo "Installed and started nic-tune.service"
  echo "Check status/logs with: systemctl status nic-tune && journalctl -u nic-tune -b"
}

main "$@"
