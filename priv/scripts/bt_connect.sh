#!/bin/bash
# Bluetooth PAN PANU client connect script for Laptop
# Usage: sudo bt_connect.sh <mac_address> [ip]

MAC=${1:-B8:27:EB:D6:9C:95}
IP=${2:-192.168.44.2}

echo "Connecting to Bluetooth PAN at $MAC..."

# Ensure bluetooth is running
systemctl start bluetooth 2>/dev/null || true
sleep 1

# Clean up any existing bt-network processes and connections
echo "Cleaning up previous connections..."
pkill -f "bt-network" 2>/dev/null || true
sleep 0.5

# Disconnect any existing connection to this device
bt-device -d "$MAC" 2>/dev/null || true
sleep 0.5

# Check if bnep0 already exists and remove it
if ip link show bnep0 &>/dev/null; then
    echo "Removing existing bnep0 interface..."
    ip link set bnep0 down 2>/dev/null || true
    ip link delete bnep0 2>/dev/null || true
    sleep 0.5
fi

# Power on and make sure we can connect
echo -e "power on\nagent on\ndefault-agent\ntrust $MAC\nquit" | bluetoothctl 2>&1 || true
sleep 1

# Check if bt-network is available
if ! command -v bt-network &> /dev/null; then
    echo "ERROR: bt-network not found. Install with: sudo pacman -S bluez-tools"
    exit 1
fi

# Connect using bt-network as PANU client
echo "Connecting to NAP server via bt-network..."
bt-network -c "$MAC" nap &
BT_PID=$!
sleep 3

# Wait for bnep0 interface (up to 20 seconds)
echo "Waiting for bnep0 interface..."
for i in {1..20}; do
  if ip link show bnep0 &>/dev/null; then
    ip link set bnep0 up
    ip addr flush dev bnep0 2>/dev/null || true
    ip addr add "$IP/24" dev bnep0
    echo "OK: Connected to $MAC, bnep0 at $IP"
    exit 0
  fi
  sleep 1
  echo "  Waiting... ($i/20)"
done

# Cleanup if failed
kill $BT_PID 2>/dev/null || true
pkill -f "bt-network" 2>/dev/null || true
echo "ERROR: bnep0 interface not found after 20 seconds"
exit 1
