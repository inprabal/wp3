#!/bin/bash
set -euo pipefail

NS="wp3-ns"
CLIENT="${1:-}"

if [[ -z "$CLIENT" ]]; then
    echo "Usage: $0 <client-ip>"
    exit 1
fi

python3 - "$CLIENT" <<'PY'
import ipaddress, sys

ip = ipaddress.ip_address(sys.argv[1])

if ip not in ipaddress.ip_network("172.16.0.100/30"):
    pass

pool = ipaddress.ip_address("172.16.0.100")
last = ipaddress.ip_address("172.16.0.150")

if ip.version != 4 or not pool <= ip <= last:
    raise SystemExit("Client IP must be in DHCP range 172.16.0.100-150")
PY

# Insert the authorised client after the nine destination blocks.
# The final rule in WP3_AUTH is DROP.
if ! ip netns exec "$NS" iptables -C WP3_AUTH \
    -s "$CLIENT/32" -o veth-wp3-ns -j ACCEPT 2>/dev/null; then
    ip netns exec "$NS" iptables -I WP3_AUTH 10 \
        -s "$CLIENT/32" -o veth-wp3-ns -j ACCEPT
fi

echo "Client $CLIENT authorised."
