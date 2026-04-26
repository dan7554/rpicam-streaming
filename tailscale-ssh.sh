#!/usr/bin/env bash
set -euo pipefail

# Tailscale SSH connection helper
# Lists your Tailscale devices and connects via SSH

DEVICES=(
  "rpicam2-1|100.80.96.23|pi"
  "rpicam3|100.79.254.101|pi"
)

show_status() {
  echo "=== Tailscale Devices ==="
  echo ""
  tailscale status 2>/dev/null | grep -v "^#" | grep -v "^$" || true
  echo ""
}

show_menu() {
  echo "=== SSH Targets ==="
  for i in "${!DEVICES[@]}"; do
    IFS='|' read -r name ip user <<< "${DEVICES[$i]}"
    echo "  $((i+1))) $name ($ip) as $user"
  done
  echo "  q) Quit"
  echo ""
}

connect() {
  IFS='|' read -r name ip user <<< "${DEVICES[$1]}"
  echo "Connecting to $name ($ip) as $user..."
  ssh "$user@$ip"
}

# Direct connect: ./tailscale-ssh.sh rpicam2-1
if [[ ${1:-} != "" ]]; then
  for i in "${!DEVICES[@]}"; do
    IFS='|' read -r name ip user <<< "${DEVICES[$i]}"
    if [[ "$name" == "$1" ]]; then
      connect "$i"
      exit 0
    fi
  done
  echo "Unknown device: $1"
  echo "Available: ${DEVICES[*]%%|*}"
  exit 1
fi

# Interactive mode
show_status
show_menu

read -rp "Select device: " choice
case "$choice" in
  q|Q) exit 0 ;;
  *)
    idx=$((choice - 1))
    if [[ $idx -ge 0 && $idx -lt ${#DEVICES[@]} ]]; then
      connect "$idx"
    else
      echo "Invalid selection"
      exit 1
    fi
    ;;
esac
