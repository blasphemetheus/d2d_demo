#!/bin/bash
# Bluetooth PAN PANU client connect script for Laptop
# Usage: sudo bt_connect.sh <mac_address> [ip]

MAC=${1:-B8:27:EB:D6:9C:95}
IP=${2:-192.168.44.2}

echo "Connecting to Bluetooth PAN at $MAC..."

# Ensure bluetooth is running
systemctl start bluetooth 2>/dev/null || true

# Kill any stale bt-network processes first
pkill -f "bt-network" 2>/dev/null || true
sleep 0.3

# Check if bnep0 already exists and working
if ip link show bnep0 &>/dev/null; then
    ip link set bnep0 up 2>/dev/null || true
    ip addr flush dev bnep0 2>/dev/null || true
    ip addr add "$IP/24" dev bnep0 2>/dev/null || true
    if ping -c 1 -W 2 192.168.44.1 &>/dev/null; then
        echo "OK: Already connected to $MAC, bnep0 at $IP"
        exit 0
    fi
    # Interface exists but not working, clean it up
    ip link set bnep0 down 2>/dev/null || true
fi

# Check if bt-network is available
if ! command -v bt-network &> /dev/null; then
    echo "ERROR: bt-network not found. Install with: sudo pacman -S bluez-tools"
    exit 1
fi

# Function to configure bnep0 when it appears
configure_bnep0() {
    ip link set bnep0 up
    ip addr flush dev bnep0 2>/dev/null || true
    ip addr add "$IP/24" dev bnep0
    echo "OK: Connected to $MAC, bnep0 at $IP"
}

# Power on bluetooth (use timeout to avoid hanging, suppress all output)
echo "Powering on bluetooth..."
timeout 3 bluetoothctl power on &>/dev/null || true

# Trust device (agent setup not needed for already-paired devices)
echo "Trusting $MAC..."
timeout 3 bluetoothctl trust "$MAC" &>/dev/null || true

# Start connect in background (often fails with "br-connection-not-supported" but that's OK)
echo "Connecting to $MAC..."
nohup timeout 10 bluetoothctl connect "$MAC" &>/dev/null 2>&1 &
sleep 1

# Start bt-network (nohup + redirect so System.cmd doesn't wait for it)
echo "Starting bt-network..."
nohup bt-network -c "$MAC" nap </dev/null &>/dev/null 2>&1 &
BT_PID=$!

# Wait for bnep0 (up to 40 seconds total)
echo "Waiting for bnep0 interface..."
for i in {1..40}; do
  if ip link show bnep0 &>/dev/null; then
    configure_bnep0
    exit 0
  fi
  sleep 1
  if (( i % 5 == 0 )); then
    echo "  Waiting... ($i/40)"
  fi
done

# Cleanup if failed
kill $BT_PID 2>/dev/null || true
pkill -f "bt-network" 2>/dev/null || true
echo "ERROR: bnep0 interface not found after 40 seconds"
exit 1
