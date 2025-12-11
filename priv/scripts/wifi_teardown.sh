#!/bin/bash
# WiFi Ad-hoc teardown script
# Usage: sudo wifi_teardown.sh [interface]
set -e

IFACE=${1:-wlan0}

echo "Tearing down WiFi ad-hoc on $IFACE..."

# Remove IP and reset interface
ip addr flush dev "$IFACE" 2>/dev/null || true
ip link set "$IFACE" down 2>/dev/null || true
iw dev "$IFACE" set type managed 2>/dev/null || true
ip link set "$IFACE" up 2>/dev/null || true

# Restart NetworkManager
systemctl start NetworkManager 2>/dev/null || true

echo "OK: Restored NetworkManager on $IFACE"
