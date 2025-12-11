#!/bin/bash
# Bluetooth PAN disconnect script for Laptop
# Usage: sudo bt_disconnect.sh [mac_address]
set -e

MAC=${1:-B8:27:EB:D6:9C:95}

echo "Disconnecting from Bluetooth PAN..."

# Disconnect
bluetoothctl disconnect "$MAC" 2>/dev/null || true

# Clean up bnep0 interface
ip link set bnep0 down 2>/dev/null || true

echo "OK: Disconnected from $MAC"
