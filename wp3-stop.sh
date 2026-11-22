#!/usr/bin/env bash
# Stop WP3 application services only.
# Automatically captures before/after snapshots.
# Preserves namespace, interfaces, routes, firewall and authorization.

set -u

ROOT="/home/kali/wifipumpkin3"
NS="wp3-ns"

if [[ $EUID -eq 0 ]]; then
    echo "Run as kali: bash ~/wifipumpkin3/wp3-stop.sh"
    exit 1
fi

capture() {
    echo
    echo "===== $1 snapshot ====="
    "$ROOT/wp3-capture-baseline.sh" || {
        echo "ERROR: Snapshot failed. Aborting operation."
        exit 1
    }
}

capture "BEFORE STOP"

sudo -v || exit 1

if ! sudo ip netns list | grep -q "^${NS}[[:space:]]"; then
    echo "ERROR: Namespace $NS does not exist."
    exit 1
fi

echo
echo "Stopping WP3..."

# Gracefully interrupt WP3 in its interactive tmux terminal.
if sudo tmux has-session -t wp3 2>/dev/null; then
    echo "Sending Ctrl+C to WP3 tmux session..."
    sudo tmux send-keys -t wp3 C-c
    sleep 3
    sudo tmux kill-session -t wp3 2>/dev/null || true
else
    echo "WP3 tmux session not found; checking for standalone process."
fi

# Fallback cleanup if the WP3 process is still running.
sudo pkill -INT -f \
    '^/usr/bin/python3 /usr/bin/wifipumpkin3 -i wlan2$' 2>/dev/null || true

sleep 3

# Stop hostapd if WP3 did not stop it itself.
sudo pkill -TERM -f \
    '^/usr/sbin/hostapd /home/kali/\.config/wifipumpkin3/config/hostapd/hostapd\.conf$' \
    2>/dev/null || true

# Stop the custom Flask portal.
sudo pkill -TERM -f \
    '^/usr/bin/python3 /home/kali/wifipumpkin3/wp3-portal\.py$' \
    2>/dev/null || true

# Stop DHCP/DNS inside the namespace.
sudo ip netns exec "$NS" pkill -TERM -x dnsmasq 2>/dev/null || true

sleep 3

echo
echo "===== Remaining WP3 processes ====="
sudo pgrep -a -f \
    'wifipumpkin3|hostapd|dnsmasq|wp3-portal.py' || true

capture "AFTER STOP"

echo
echo "WP3 stop operation completed."
echo "Network isolation infrastructure was not modified."
