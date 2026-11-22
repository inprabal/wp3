#!/usr/bin/env bash

set -euo pipefail

NS="wp3-ns"
CLIENT="${1:-}"

if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo: sudo $0 <client-ip>"
    exit 1
fi

if [[ -z "$CLIENT" ]]; then
    echo "Usage: sudo $0 <client-ip>"
    echo "Example: sudo $0 172.16.0.105"
    exit 1
fi

# Validate that the client belongs to the WP3 DHCP pool.
python3 - "$CLIENT" <<'PY'
import ipaddress
import sys

try:
    ip = ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit("Invalid IP address")

if ip.version != 4:
    raise SystemExit("IPv4 addresses only")

if not ipaddress.ip_address("172.16.0.100") <= ip <= ipaddress.ip_address("172.16.0.150"):
    raise SystemExit("IP must be within 172.16.0.100-172.16.0.150")
PY

if ! ip netns list | grep -q "^${NS}\b"; then
    echo "ERROR: Network namespace $NS does not exist."
    exit 1
fi

# Verify both chains exist.
ip netns exec "$NS" iptables -S WP3_AUTH >/dev/null
ip netns exec "$NS" iptables -t nat -S WP3_CAPTIVE >/dev/null

remove_rule() {
    local table="$1"
    local chain="$2"
    shift 2

    local count=0

    while ip netns exec "$NS" iptables -t "$table" -C "$chain" "$@" 2>/dev/null; do
        ip netns exec "$NS" iptables -t "$table" -D "$chain" "$@"
        ((count += 1))
    done

    echo "$chain: removed $count matching rule(s)"
}

echo "Revoking WP3 authorization for $CLIENT..."

remove_rule filter WP3_AUTH \
    -s "$CLIENT/32" -o veth-wp3-ns -j ACCEPT

remove_rule nat WP3_CAPTIVE \
    -s "$CLIENT/32" -j RETURN

echo "Authorization revoked for $CLIENT."
echo "The client must complete the captive portal again."
