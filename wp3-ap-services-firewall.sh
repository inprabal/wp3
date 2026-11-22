#!/bin/bash
set -euo pipefail

NS="wp3-ns"
AP="wlan2"
AP_IP="172.16.0.1"

echo "Configuring WP3 DHCP/DNS firewall permissions..."

# Allow DHCP client requests to the namespace DHCP server
ip netns exec "$NS" iptables -C INPUT -i "$AP" \
    -p udp --sport 68 --dport 67 -j ACCEPT 2>/dev/null ||
ip netns exec "$NS" iptables -A INPUT -i "$AP" \
    -p udp --sport 68 --dport 67 -j ACCEPT

# Allow DNS over UDP
ip netns exec "$NS" iptables -C INPUT -i "$AP" \
    -d "$AP_IP" -p udp --dport 53 -j ACCEPT 2>/dev/null ||
ip netns exec "$NS" iptables -A INPUT -i "$AP" \
    -d "$AP_IP" -p udp --dport 53 -j ACCEPT

# Allow DNS over TCP
ip netns exec "$NS" iptables -C INPUT -i "$AP" \
    -d "$AP_IP" -p tcp --dport 53 -j ACCEPT 2>/dev/null ||
ip netns exec "$NS" iptables -A INPUT -i "$AP" \
    -d "$AP_IP" -p tcp --dport 53 -j ACCEPT

echo "DHCP/DNS firewall permissions configured."

# Allow upstream DNS replies arriving from the host transit link.
for DNS_SERVER in 1.1.1.1 8.8.8.8; do
    ip netns exec "$NS" iptables -C INPUT \
        -i veth-wp3-ns -d 169.254.250.2 \
        -s "$DNS_SERVER" -p udp --sport 53 \
        -m conntrack --ctstate ESTABLISHED -j ACCEPT 2>/dev/null ||
    ip netns exec "$NS" iptables -I INPUT 3 \
        -i veth-wp3-ns -d 169.254.250.2 \
        -s "$DNS_SERVER" -p udp --sport 53 \
        -m conntrack --ctstate ESTABLISHED -j ACCEPT
done
