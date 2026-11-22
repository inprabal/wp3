#!/bin/bash
set -euo pipefail

NS="wp3-ns"
AP="wlan2"
UPLINK="veth-wp3-ns"

echo "Configuring WP3 authorised-client firewall..."

# Create and initialise only our dedicated chain.
ip netns exec "$NS" iptables -N WP3_AUTH 2>/dev/null || true
ip netns exec "$NS" iptables -F WP3_AUTH

# Block private, local and non-routable destinations.
for NET in \
    0.0.0.0/8 \
    10.0.0.0/8 \
    100.64.0.0/10 \
    127.0.0.0/8 \
    169.254.0.0/16 \
    172.16.0.0/12 \
    192.168.0.0/16 \
    224.0.0.0/4 \
    240.0.0.0/4
do
    ip netns exec "$NS" iptables -A WP3_AUTH \
        -d "$NET" -j DROP
done

# Final deny: only explicitly authorised clients are inserted
# before this rule by wp3-authorize.sh.
ip netns exec "$NS" iptables -A WP3_AUTH -j DROP

# Route AP-client forwarding through our dedicated chain.
ip netns exec "$NS" iptables -C FORWARD \
    -i "$AP" -j WP3_AUTH 2>/dev/null ||
ip netns exec "$NS" iptables -I FORWARD 1 \
    -i "$AP" -j WP3_AUTH

# Permit established return traffic.
ip netns exec "$NS" iptables -C FORWARD \
    -i "$UPLINK" -o "$AP" \
    -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null ||
ip netns exec "$NS" iptables -I FORWARD 1 \
    -i "$UPLINK" -o "$AP" \
    -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

echo "WP3 authorised-client firewall configured."
