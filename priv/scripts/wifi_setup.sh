#!/bin/bash
# WiFi Ad-hoc setup script for Laptop
# Usage: sudo wifi_setup.sh [interface] [ssid] [freq] [ip]
set -e

IFACE=${1:-wlan0}
SSID=${2:-PiAdhoc}
FREQ=${3:-2437}
IP=${4:-192.168.12.2}

echo "Setting up WiFi ad-hoc on $IFACE..."

# Stop NetworkManager if running
systemctl stop NetworkManager 2>/dev/null || true

# Configure interface for ad-hoc mode
ip link set "$IFACE" down
iw dev "$IFACE" set type ibss
ip link set "$IFACE" up

# Join ad-hoc network
iw dev "$IFACE" ibss join "$SSID" "$FREQ"

# Assign IP address
ip addr flush dev "$IFACE"
ip addr add "$IP/24" dev "$IFACE"

echo "OK: Ad-hoc network '$SSID' on $IFACE at $IP"
