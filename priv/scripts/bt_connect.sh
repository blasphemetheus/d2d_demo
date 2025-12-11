#!/bin/bash
# Bluetooth PAN PANU client connect script for Laptop
# Usage: sudo bt_connect.sh <mac_address> [ip]
set -e

MAC=${1:-B8:27:EB:D6:9C:95}
IP=${2:-192.168.44.2}

echo "Connecting to Bluetooth PAN at $MAC..."

# Ensure bluetooth is running
systemctl start bluetooth 2>/dev/null || true
sleep 1

# Power on and connect
bluetoothctl power on
bluetoothctl agent on
bluetoothctl default-agent

# Connect to the device
bluetoothctl connect "$MAC"

# Wait for bnep0 interface (up to 15 seconds)
echo "Waiting for bnep0 interface..."
for i in {1..15}; do
  if ip link show bnep0 &>/dev/null; then
    ip link set bnep0 up
    ip addr flush dev bnep0 2>/dev/null || true
    ip addr add "$IP/24" dev bnep0
    echo "OK: Connected to $MAC, bnep0 at $IP"
    exit 0
  fi
  sleep 1
  echo "  Waiting... ($i/15)"
done

echo "ERROR: bnep0 interface not found after 15 seconds"
exit 1
