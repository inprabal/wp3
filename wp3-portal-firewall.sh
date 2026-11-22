#!/bin/bash
set -euo pipefail

NS="wp3-ns"
AP="wlan2"
PORTAL_IP="172.16.0.1"

echo "Allowing access to WP3 captive portal..."

ip netns exec "$NS" iptables -C INPUT \
    -i "$AP" -s 172.16.0.0/24 \
    -d "$PORTAL_IP" -p tcp --dport 8080 \
    -j ACCEPT 2>/dev/null ||
ip netns exec "$NS" iptables -A INPUT \
    -i "$AP" -s 172.16.0.0/24 \
    -d "$PORTAL_IP" -p tcp --dport 8080 \
    -j ACCEPT

echo "Captive portal access rule prepared."
