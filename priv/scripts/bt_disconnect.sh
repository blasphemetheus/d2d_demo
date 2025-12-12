#!/bin/bash
# Bluetooth PAN disconnect script for Laptop
# Usage: sudo bt_disconnect.sh [mac_address]

MAC=${1:-B8:27:EB:D6:9C:95}

echo "Disconnecting from Bluetooth PAN..."

# Kill any bt-network processes
echo "Stopping bt-network processes..."
pkill -f "bt-network" 2>/dev/null || true
sleep 0.5

# Disconnect using bt-device first (cleaner)
echo "Attempting to disconnect from $MAC"
bt-device -d "$MAC" 2>/dev/null || true

# Then bluetoothctl
bluetoothctl disconnect "$MAC" 2>/dev/null || true

# Clean up bnep0 interface
if ip link show bnep0 &>/dev/null; then
    echo "Removing bnep0 interface..."
    ip link set bnep0 down 2>/dev/null || true
    ip link delete bnep0 2>/dev/null || true
fi

echo "OK: Disconnected from $MAC"
