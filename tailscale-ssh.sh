#!/usr/bin/env bash
set -euo pipefail

# Tailscale SSH connection helper
# Auto-discovers rpicam* devices from Tailscale and connects via SSH

SSH_USER="${FLEET_SSH_USER:-dan7554}"

# Discover online rpicam* devices from Tailscale
discover_devices() {
  local devices=()
  while IFS=$'\t' read -r ip name status; do
    devices+=("$name|$ip|$SSH_USER")
  done < <(tailscale status 2>/dev/null | grep -i "rpicam" | awk '{print $1 "\t" $2 "\t" $6}')
  if [ ${#devices[@]} -eq 0 ]; then
    echo "No rpicam* devices found on Tailscale. Is Tailscale running?"
    exit 1
  fi
  echo "${devices[@]}"
}

read -ra DEVICES <<< "$(discover_devices)"

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
