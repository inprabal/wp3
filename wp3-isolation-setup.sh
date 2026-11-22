#!/usr/bin/env bash
#
# wp3-isolation-setup.sh
#
# Stage 1: create the dedicated WP3 network namespace and host-side veth.
# Default mode is DRY RUN. Nothing changes unless --apply is supplied and
# the operator confirms interactively.
#
# This stage deliberately does NOT:
#   - move wlan2 into the namespace;
#   - change NetworkManager or wpa_supplicant;
#   - start WiFi-Pumpkin3 or hostapd;
#   - change the host's global forwarding sysctl;
#   - flush or rewrite existing firewall chains;
#   - stop or modify Docker.
#
set -Eeuo pipefail
umask 077
export LC_ALL=C

CONFIG="./wp3-isolation.conf"
APPLY=0

usage() {
  cat <<'USAGE'
Usage: sudo ./wp3-isolation-setup.sh [--config PATH] [--apply]

Without --apply, prints the planned operations only.
With --apply, creates the WP3 namespace, veth pair, narrow host firewall
rules and namespace firewall. It does not move wlan2 or start WP3.
USAGE
}

while (($#)); do
  case "$1" in
    --config)
      [[ $# -ge 2 ]] || { echo "Missing --config path" >&2; exit 2; }
      CONFIG="$2"
      shift 2
      ;;
    --apply)
      APPLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "ERROR: run with sudo." >&2; exit 1; }
[[ -r "$CONFIG" ]] || { echo "ERROR: cannot read config: $CONFIG" >&2; exit 1; }

# shellcheck disable=SC1090
source "$CONFIG"

: "${WP3_NETNS:?Missing WP3_NETNS}"
: "${VETH_HOST:?Missing VETH_HOST}"
: "${VETH_NS:?Missing VETH_NS}"
: "${WP3_INTERFACE:?Missing WP3_INTERFACE}"
: "${UPLINK_INTERFACE:?Missing UPLINK_INTERFACE}"
: "${WP3_SUBNET:?Missing WP3_SUBNET}"
: "${TRANSIT_HOST_IP:?Missing TRANSIT_HOST_IP}"
: "${TRANSIT_NS_IP:?Missing TRANSIT_NS_IP}"
: "${TRANSIT_SUBNET:?Missing TRANSIT_SUBNET}"
: "${WP3_STATE_DIR:?Missing WP3_STATE_DIR}"

IP="$(command -v ip)"
IPT="$(command -v iptables-legacy || command -v iptables)"
IP6T="$(command -v ip6tables-legacy || command -v ip6tables)"
SYSCTL="$(command -v sysctl)"

for cmd in "$IP" "$IPT" "$IP6T" "$SYSCTL"; do
  [[ -x "$cmd" ]] || {
    echo "ERROR: required command unavailable: $cmd" >&2
    exit 1
  }
done

# Reject unexpected names and malformed addresses before constructing rules.
[[ "$WP3_NETNS" =~ ^[a-zA-Z0-9_.-]{1,32}$ ]] || {
  echo "Invalid namespace name" >&2
  exit 1
}
[[ "$VETH_HOST" =~ ^[a-zA-Z0-9_.-]{1,15}$ ]] || {
  echo "Invalid host veth name" >&2
  exit 1
}
[[ "$VETH_NS" =~ ^[a-zA-Z0-9_.-]{1,15}$ ]] || {
  echo "Invalid namespace veth name" >&2
  exit 1
}
[[ "$WP3_SUBNET" =~ ^[0-9./]+$ && "$TRANSIT_SUBNET" =~ ^[0-9./]+$ ]] || {
  echo "Invalid CIDR syntax in config" >&2
  exit 1
}
[[ "$TRANSIT_HOST_IP" =~ ^[0-9.]+$ && "$TRANSIT_NS_IP" =~ ^[0-9.]+$ ]] || {
  echo "Invalid transit IP syntax in config" >&2
  exit 1
}

STATE_DIR="$WP3_STATE_DIR"
FWD_CHAIN="WP3_ISO_FWD"
INPUT_CHAIN="WP3_ISO_IN"

NAT_COMMENT="WP3_ISOLATION_NAT"
NAT_DNS_UDP_COMMENT="WP3_ISOLATION_DNS_UDP"
NAT_DNS_TCP_COMMENT="WP3_ISOLATION_DNS_TCP"
NAT_TRANSIT_COMMENT="WP3_ISOLATION_TRANSIT_NAT"

# Never adopt or overwrite an existing namespace or same-named interfaces.
if "$IP" netns list | awk '{print $1}' | grep -Fxq "$WP3_NETNS"; then
  echo "ERROR: namespace $WP3_NETNS already exists; refusing to modify it." >&2
  exit 1
fi

if "$IP" link show "$VETH_HOST" >/dev/null 2>&1; then
  echo "ERROR: interface $VETH_HOST already exists; refusing to modify it." >&2
  exit 1
fi

if "$IP" link show "$VETH_NS" >/dev/null 2>&1; then
  echo "ERROR: interface $VETH_NS already exists; refusing to modify it." >&2
  exit 1
fi

if ! "$IP" link show "$UPLINK_INTERFACE" >/dev/null 2>&1; then
  echo "ERROR: uplink $UPLINK_INTERFACE does not exist." >&2
  exit 1
fi

if ! "$IP" link show "$WP3_INTERFACE" >/dev/null 2>&1; then
  echo "ERROR: AP interface $WP3_INTERFACE does not exist." >&2
  exit 1
fi

if [[ -n $("${IP}" route show exact "$WP3_SUBNET" 2>/dev/null) ]]; then
  echo "ERROR: host already has a route for $WP3_SUBNET; refusing to overlap it." >&2
  exit 1
fi

# This stage requires the host's existing IPv4 forwarding to remain enabled.
# It deliberately refuses to change it.
HOST_FORWARD="$("$SYSCTL" -n net.ipv4.ip_forward)"
[[ "$HOST_FORWARD" == "1" ]] || {
  echo "ERROR: host IPv4 forwarding is not enabled. No sysctl change will be made." >&2
  exit 1
}

# Do not proceed if our reserved chain names already exist.
if "$IPT" -S "$FWD_CHAIN" >/dev/null 2>&1; then
  echo "ERROR: host chain $FWD_CHAIN already exists; refusing to adopt it." >&2
  exit 1
fi

if "$IPT" -S "$INPUT_CHAIN" >/dev/null 2>&1; then
  echo "ERROR: host chain $INPUT_CHAIN already exists; refusing to adopt it." >&2
  exit 1
fi

cat <<PLAN
===== WP3 ISOLATION SETUP: STAGE 1 =====
Mode:             $([[ $APPLY -eq 1 ]] && echo APPLY || echo DRY RUN)
Namespace:        $WP3_NETNS
Host veth:        $VETH_HOST ($TRANSIT_HOST_IP/30)
Namespace veth:   $VETH_NS ($TRANSIT_NS_IP/30)
AP interface:     $WP3_INTERFACE (NOT moved in this stage)
Internet uplink:  $UPLINK_INTERFACE
AP subnet:        $WP3_SUBNET
Host IPv4 forward:$HOST_FORWARD (unchanged)

Planned changes in APPLY mode:
  1. Create the WP3 network namespace.
  2. Create and configure the veth pair and namespace default route.
  3. Add a host route for the AP subnet through the namespace veth.
  4. Create dedicated host INPUT/FORWARD chains and insert WP3-specific
     jump rules; do not flush or alter Docker chains.
  5. Add narrowly scoped IPv4 MASQUERADE for AP traffic via $UPLINK_INTERFACE.
  6. Permit namespace-originated DNS (UDP/TCP 53) through $UPLINK_INTERFACE
     and NAT only that DNS traffic.
  7. Install a default-deny namespace firewall. AP-client forwarding remains
     blocked until a later authorisation stage.
  8. Apply namespace IPv6 input/forward blocking.

Not performed:
  - No wlan2 movement, Wi-Fi mode changes, NetworkManager changes or WP3 start.
  - No changes to existing Docker containers, networks, chains or port mappings.
  - No global firewall flush, chain deletion or iptables-alternative changes.
  - No host global sysctl changes.
PLAN

if (( ! APPLY )); then
  echo
  echo "DRY RUN ONLY. Review the plan; rerun with --apply to make these changes."
  exit 0
fi

[[ -t 0 ]] || {
  echo "ERROR: --apply requires an interactive terminal." >&2
  exit 1
}

read -r -p "Type exactly CREATE-WP3-NAMESPACE to continue: " answer
[[ "$answer" == "CREATE-WP3-NAMESPACE" ]] || {
  echo "Cancelled."
  exit 0
}

# Create state directory only after explicit confirmation.
install -d -m 0700 "$STATE_DIR"
STATE_FILE="$STATE_DIR/setup.state"

[[ ! -e "$STATE_FILE" ]] || {
  echo "ERROR: state file already exists: $STATE_FILE" >&2
  exit 1
}

created_ns=0
created_veth=0
created_route=0
created_fwd=0
created_input=0
created_nat=0
created_dns_udp_nat=0
created_dns_tcp_nat=0
created_transit_nat=0
created_fwd_return_jump=0
created_fwd_in_jump=0
created_v6_input=0
created_v6_fwd_in=0
created_v6_fwd_out=0

cleanup_on_error() {
  rc=$?

  if (( rc != 0 )); then
    echo "ERROR: setup failed; attempting cleanup of resources created by this run." >&2

    if (( created_transit_nat )); then
      "$IPT" -t nat -D POSTROUTING \
        -s "$TRANSIT_NS_IP" -o "$UPLINK_INTERFACE" \
        -m comment --comment "$NAT_TRANSIT_COMMENT" \
        -j MASQUERADE 2>/dev/null || true
    fi
    if (( created_dns_tcp_nat )); then
      "$IPT" -t nat -D POSTROUTING \
        -s "$TRANSIT_NS_IP" -o "$UPLINK_INTERFACE" \
        -p tcp --dport 53 \
        -m comment --comment "$NAT_DNS_TCP_COMMENT" \
        -j MASQUERADE 2>/dev/null || true
    fi

    if (( created_dns_udp_nat )); then
      "$IPT" -t nat -D POSTROUTING \
        -s "$TRANSIT_NS_IP" -o "$UPLINK_INTERFACE" \
        -p udp --dport 53 \
        -m comment --comment "$NAT_DNS_UDP_COMMENT" \
        -j MASQUERADE 2>/dev/null || true
    fi

    if (( created_nat )); then
      "$IPT" -t nat -D POSTROUTING \
        -s "$WP3_SUBNET" -o "$UPLINK_INTERFACE" \
        -m comment --comment "$NAT_COMMENT" \
        -j MASQUERADE 2>/dev/null || true
    fi

    if (( created_fwd_return_jump )); then
      "$IPT" -D FORWARD -o "$VETH_HOST" -j "$FWD_CHAIN" 2>/dev/null || true
    fi

    if (( created_fwd_in_jump )); then
      "$IPT" -D FORWARD -i "$VETH_HOST" -j "$FWD_CHAIN" 2>/dev/null || true
    fi

    if (( created_fwd )); then
      "$IPT" -F "$FWD_CHAIN" 2>/dev/null || true
      "$IPT" -X "$FWD_CHAIN" 2>/dev/null || true
    fi

    if (( created_v6_input )); then
      "$IP6T" -D INPUT -i "$VETH_HOST" -j DROP 2>/dev/null || true
    fi

    if (( created_v6_fwd_in )); then
      "$IP6T" -D FORWARD -i "$VETH_HOST" -j DROP 2>/dev/null || true
    fi

    if (( created_v6_fwd_out )); then
      "$IP6T" -D FORWARD -o "$VETH_HOST" -j DROP 2>/dev/null || true
    fi

    if (( created_input )); then
      "$IPT" -D INPUT -i "$VETH_HOST" -j "$INPUT_CHAIN" 2>/dev/null || true
      "$IPT" -F "$INPUT_CHAIN" 2>/dev/null || true
      "$IPT" -X "$INPUT_CHAIN" 2>/dev/null || true
    fi

    if (( created_route )); then
      "$IP" route del "$WP3_SUBNET" \
        via "$TRANSIT_NS_IP" dev "$VETH_HOST" 2>/dev/null || true
    fi

    if (( created_veth )); then
      "$IP" link del "$VETH_HOST" 2>/dev/null || true
    fi

    if (( created_ns )); then
      "$IP" netns del "$WP3_NETNS" 2>/dev/null || true
    fi
  fi

  exit "$rc"
}

trap cleanup_on_error EXIT

# Create namespace and transit link.
"$IP" netns add "$WP3_NETNS"
created_ns=1

"$IP" link add "$VETH_HOST" type veth peer name "$VETH_NS"
created_veth=1

"$IP" link set "$VETH_NS" netns "$WP3_NETNS"

"$IP" addr add "$TRANSIT_HOST_IP/30" dev "$VETH_HOST"
"$IP" link set "$VETH_HOST" up

"$IP" route add "$WP3_SUBNET" via "$TRANSIT_NS_IP" dev "$VETH_HOST"
created_route=1

"$IP" -n "$WP3_NETNS" link set lo up
"$IP" -n "$WP3_NETNS" addr add "$TRANSIT_NS_IP/30" dev "$VETH_NS"
"$IP" -n "$WP3_NETNS" link set "$VETH_NS" up
"$IP" -n "$WP3_NETNS" route add default via "$TRANSIT_HOST_IP"

# Host INPUT: block all traffic arriving from the WP3 transit interface.
"$IPT" -N "$INPUT_CHAIN"
created_input=1

"$IPT" -A "$INPUT_CHAIN" -j DROP
"$IPT" -I INPUT 1 -i "$VETH_HOST" -j "$INPUT_CHAIN"

# Host FORWARD: permit AP client traffic only to the selected uplink.
# Permit namespace DNS queries only to the selected uplink.
# Permit established return traffic for AP clients and namespace DNS.
# Everything else arriving from or routed to the veth is dropped.
"$IPT" -N "$FWD_CHAIN"
created_fwd=1

# AP client traffic toward internet (later namespace rules control authorisation).
"$IPT" -A "$FWD_CHAIN" \
  -i "$VETH_HOST" -o "$UPLINK_INTERFACE" \
  -s "$WP3_SUBNET" -j ACCEPT

# Namespace-originated DNS queries only.
"$IPT" -A "$FWD_CHAIN" \
  -i "$VETH_HOST" -o "$UPLINK_INTERFACE" \
  -s "$TRANSIT_NS_IP" -p udp --dport 53 -j ACCEPT

"$IPT" -A "$FWD_CHAIN" \
  -i "$VETH_HOST" -o "$UPLINK_INTERFACE" \
  -s "$TRANSIT_NS_IP" -p tcp --dport 53 -j ACCEPT

# General namespace transit traffic toward the selected uplink.
"$IPT" -A "$FWD_CHAIN" \
  -i "$VETH_HOST" -o "$UPLINK_INTERFACE" \
  -s "$TRANSIT_NS_IP" -j ACCEPT

# Established replies to AP clients.
"$IPT" -A "$FWD_CHAIN" \
  -i "$UPLINK_INTERFACE" -o "$VETH_HOST" \
  -d "$WP3_SUBNET" \
  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Established DNS replies to the namespace transit address.
"$IPT" -A "$FWD_CHAIN" \
  -i "$UPLINK_INTERFACE" -o "$VETH_HOST" \
  -d "$TRANSIT_NS_IP" \
  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Deny all other forwarded traffic involving the WP3 transit interface.
"$IPT" -A "$FWD_CHAIN" -j DROP

"$IPT" -I FORWARD 1 -o "$VETH_HOST" -j "$FWD_CHAIN"
created_fwd_return_jump=1

"$IPT" -I FORWARD 1 -i "$VETH_HOST" -j "$FWD_CHAIN"
created_fwd_in_jump=1

# Explicitly block IPv6 arriving from or routed to the WP3 transit link.
"$IP6T" -I INPUT 1 -i "$VETH_HOST" -j DROP
created_v6_input=1

"$IP6T" -I FORWARD 1 -i "$VETH_HOST" -j DROP
created_v6_fwd_in=1

"$IP6T" -I FORWARD 1 -o "$VETH_HOST" -j DROP
created_v6_fwd_out=1

# AP-client NAT rule.
"$IPT" -t nat -A POSTROUTING \
  -s "$WP3_SUBNET" -o "$UPLINK_INTERFACE" \
  -m comment --comment "$NAT_COMMENT" \
  -j MASQUERADE
created_nat=1

# Namespace DNS NAT rules. These do not NAT general namespace traffic.
"$IPT" -t nat -A POSTROUTING \
  -s "$TRANSIT_NS_IP" -o "$UPLINK_INTERFACE" \
  -p udp --dport 53 \
  -m comment --comment "$NAT_DNS_UDP_COMMENT" \
  -j MASQUERADE
created_dns_udp_nat=1

"$IPT" -t nat -A POSTROUTING \
  -s "$TRANSIT_NS_IP" -o "$UPLINK_INTERFACE" \
  -p tcp --dport 53 \
  -m comment --comment "$NAT_DNS_TCP_COMMENT" \
  -j MASQUERADE
created_dns_tcp_nat=1

# General namespace transit NAT, after the DNS-specific NAT rules.
"$IPT" -t nat -A POSTROUTING \
  -s "$TRANSIT_NS_IP" -o "$UPLINK_INTERFACE" \
  -m comment --comment "$NAT_TRANSIT_COMMENT" \
  -j MASQUERADE
created_transit_nat=1

# Namespace firewall. AP interface is not present yet.
# FORWARD remains default-deny until a later authorisation stage.
NS_IPT=("$IP" netns exec "$WP3_NETNS" "$IPT")

"${NS_IPT[@]}" -P INPUT DROP
"${NS_IPT[@]}" -P FORWARD DROP
"${NS_IPT[@]}" -P OUTPUT ACCEPT

"$IP" netns exec "$WP3_NETNS" "$SYSCTL" \
  -w net.ipv4.ip_forward=1 >/dev/null

"${NS_IPT[@]}" -A INPUT -i lo -j ACCEPT
"${NS_IPT[@]}" -A INPUT \
  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

NS_IP6T=("$IP" netns exec "$WP3_NETNS" "$IP6T")

"${NS_IP6T[@]}" -P INPUT DROP
"${NS_IP6T[@]}" -P FORWARD DROP
"${NS_IP6T[@]}" -P OUTPUT DROP

"${NS_IP6T[@]}" -A INPUT -i lo -j ACCEPT
"${NS_IP6T[@]}" -A INPUT \
  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Record the exact resources created by this stage for later rollback.
cat > "$STATE_FILE" <<STATE
WP3_SETUP_STAGE1=complete
WP3_NETNS=$WP3_NETNS
VETH_HOST=$VETH_HOST
VETH_NS=$VETH_NS
UPLINK_INTERFACE=$UPLINK_INTERFACE
WP3_SUBNET=$WP3_SUBNET
TRANSIT_HOST_IP=$TRANSIT_HOST_IP
TRANSIT_NS_IP=$TRANSIT_NS_IP
FWD_CHAIN=$FWD_CHAIN
INPUT_CHAIN=$INPUT_CHAIN
NAT_COMMENT=$NAT_COMMENT
NAT_DNS_UDP_COMMENT=$NAT_DNS_UDP_COMMENT
NAT_DNS_TCP_COMMENT=$NAT_DNS_TCP_COMMENT
NAT_TRANSIT_COMMENT=$NAT_TRANSIT_COMMENT
HOST_IPV6_INPUT_DROP=1
HOST_IPV6_FORWARD_DROP=1
DNS_UDP_NAT=1
DNS_TCP_NAT=1
TRANSIT_NAT=1
STATE

chmod 0600 "$STATE_FILE"

trap - EXIT

echo
echo "STAGE 1 COMPLETE."
echo "Namespace and isolated transit link are configured."
echo "Namespace DNS forwarding through $UPLINK_INTERFACE is narrowly permitted."
echo "wlan2 has NOT been moved; WP3 has NOT been started."
echo "AP-client internet forwarding remains blocked by namespace FORWARD policy."
echo "State recorded in: $STATE_FILE"
echo "Next: inspect the state and firewall before the wireless/start stage."
