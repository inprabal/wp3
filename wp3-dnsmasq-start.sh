#!/bin/bash
set -euo pipefail

NAMESPACE="wp3-ns"
CONFIG="/etc/wp3/dnsmasq.conf"
PIDFILE="/run/wp3-dnsmasq.pid"
LOGFILE="/var/log/wp3-dnsmasq.log"

echo "Starting WP3 DHCP/DNS service..."

# Confirm the namespace and AP interface exist
ip netns exec "$NAMESPACE" ip link show wlan2 >/dev/null

# Prevent duplicate instances
if ip netns exec "$NAMESPACE" pgrep -x dnsmasq >/dev/null 2>&1; then
    echo "ERROR: dnsmasq is already running in $NAMESPACE"
    exit 1
fi

# Start dnsmasq inside the WP3 network namespace
ip netns exec "$NAMESPACE" dnsmasq \
    --conf-file="$CONFIG" \
    --pid-file="$PIDFILE" \
    --log-facility="$LOGFILE"

echo "WP3 DHCP/DNS service started."
echo "DHCP range: 172.16.0.100-172.16.0.150"
echo "Gateway/DNS: 172.16.0.1"
