#!/bin/bash
# Bluetooth PAN PANU client connect script for Laptop
# Usage: sudo bt_connect.sh <mac_address> [ip]

MAC=${1:-B8:27:EB:D6:9C:95}
IP=${2:-192.168.44.2}

echo "Connecting to Bluetooth PAN at $MAC..."

# Ensure bluetooth is running
systemctl start bluetooth 2>/dev/null || true

# Check if bnep0 already exists and working
if ip link show bnep0 &>/dev/null; then
    ip link set bnep0 up 2>/dev/null || true
    ip addr flush dev bnep0 2>/dev/null || true
    ip addr add "$IP/24" dev bnep0 2>/dev/null || true
    if ping -c 1 -W 2 192.168.44.1 &>/dev/null; then
        echo "OK: Already connected to $MAC, bnep0 at $IP"
        exit 0
    fi
fi

# Check if bt-network is available
if ! command -v bt-network &> /dev/null; then
    echo "ERROR: bt-network not found. Install with: sudo pacman -S bluez-tools"
    exit 1
fi

# Power on bluetooth
bluetoothctl power on 2>/dev/null || true

# Try bt-network first (works if already paired and Pi NAP is running)
echo "Attempting bt-network connection..."
pkill -f "bt-network" 2>/dev/null || true
sleep 0.5
bt-network -c "$MAC" nap &
BT_PID=$!

# Wait for bnep0 (first attempt - 15 seconds)
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

# First attempt failed - try with bluetoothctl connect
echo "First attempt failed, trying bluetoothctl connect..."
kill $BT_PID 2>/dev/null || true
pkill -f "bt-network" 2>/dev/null || true

# Connect via bluetoothctl then bt-network
bluetoothctl << EOF
power on
agent on
default-agent
trust $MAC
connect $MAC
EOF
sleep 3

bt-network -c "$MAC" nap &
BT_PID=$!

# Wait for bnep0 (second attempt - 30 seconds)
echo "Waiting for bnep0 interface..."
for i in {1..30}; do
  if ip link show bnep0 &>/dev/null; then
    ip link set bnep0 up
    ip addr flush dev bnep0 2>/dev/null || true
    ip addr add "$IP/24" dev bnep0
    echo "OK: Connected to $MAC, bnep0 at $IP"
    exit 0
  fi
  sleep 1
  echo "  Waiting... ($i/30)"
done

# Cleanup if failed
kill $BT_PID 2>/dev/null || true
pkill -f "bt-network" 2>/dev/null || true
echo "ERROR: bnep0 interface not found after multiple attempts"
exit 1
