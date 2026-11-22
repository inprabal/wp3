#!/usr/bin/env bash
#
# WiFi-Pumpkin3 Isolation Preflight
# Version: 1.0
#
# PURPOSE:
# Read-only compatibility and safety assessment before WP3 isolation.
#
# DOES NOT:
# - Create or delete network namespaces
# - Change interface states or IP addresses
# - Modify routes or firewall rules
# - Start or stop WP3, BeEF or Docker
# - Modify WP3 configuration or source code
#

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/wp3-isolation.conf"

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

pass() {
    printf '[PASS] %s\n' "$1"
    ((PASS_COUNT+=1))
}

warn() {
    printf '[WARN] %s\n' "$1"
    ((WARN_COUNT+=1))
}

fail() {
    printf '[FAIL] %s\n' "$1"
    ((FAIL_COUNT+=1))
}

section() {
    printf '\n========== %s ==========\n' "$1"
}

printf '%s\n' "======================================================"
printf '%s\n' " WiFi-Pumpkin3 Isolation Preflight Verification"
printf '%s\n' " Host: $(hostname)"
printf '%s\n' " Date: $(date)"
printf '%s\n' "======================================================"

# ------------------------------------------------------
# 1. Privileges
# ------------------------------------------------------

section "1. Execution Privileges"

if [[ "$EUID" -eq 0 ]]; then
    pass "Running with root privileges"
else
    warn "Not running as root; some checks may be incomplete"
    warn "Recommended: sudo bash ./wp3-isolation-preflight.sh"
fi

# ------------------------------------------------------
# 2. Configuration
# ------------------------------------------------------

section "2. Central Configuration"

if [[ ! -f "$CONFIG_FILE" ]]; then
    fail "Configuration file not found: $CONFIG_FILE"
    printf '\nPreflight cannot continue without configuration.\n'
    exit 1
fi

# Load the locally maintained configuration.
# This file must be trusted because Bash source executes its contents.
if ! source "$CONFIG_FILE"; then
    fail "Could not load configuration file"
    exit 1
fi

pass "Configuration file loaded"

REQUIRED_VARIABLES=(
    WP3_INTERFACE
    UPLINK_INTERFACE
    WP3_NETNS
    WP3_SUBNET
    WP3_GATEWAY
    TRANSIT_SUBNET
    TRANSIT_HOST_IP
    TRANSIT_NS_IP
    WP3_STATE_DIR
)

CONFIG_VALID=true

for variable in "${REQUIRED_VARIABLES[@]}"; do
    if [[ -z "${!variable:-}" ]]; then
        fail "Required configuration variable is empty: $variable"
        CONFIG_VALID=false
    fi
done

if [[ "$CONFIG_VALID" == true ]]; then
    pass "Required configuration variables are populated"
fi

printf 'WP3 interface : %s\n' "${WP3_INTERFACE:-UNSET}"
printf 'Uplink        : %s\n' "${UPLINK_INTERFACE:-UNSET}"
printf 'Namespace     : %s\n' "${WP3_NETNS:-UNSET}"
printf 'AP subnet     : %s\n' "${WP3_SUBNET:-UNSET}"
printf 'AP gateway    : %s\n' "${WP3_GATEWAY:-UNSET}"
printf 'Transit subnet: %s\n' "${TRANSIT_SUBNET:-UNSET}"

# ------------------------------------------------------
# 3. Required commands
# ------------------------------------------------------

section "3. Required System Commands"

REQUIRED_COMMANDS=(
    ip
    iw
    ss
    grep
    awk
    sed
    python3
)

for cmd in "${REQUIRED_COMMANDS[@]}"; do
    if command -v "$cmd" >/dev/null 2>&1; then
        pass "Command available: $cmd"
    else
        fail "Command missing: $cmd"
    fi
done

OPTIONAL_COMMANDS=(
    iptables
    ip6tables
    iptables-save
    ip6tables-save
    hostapd
    dnsmasq
    arp-scan
    docker
)

for cmd in "${OPTIONAL_COMMANDS[@]}"; do
    if command -v "$cmd" >/dev/null 2>&1; then
        pass "Optional command available: $cmd"
    else
        warn "Optional command not found: $cmd"
    fi
done

# ------------------------------------------------------
# 4. Network interfaces
# ------------------------------------------------------

section "4. Network Interface Verification"

for iface in "${WP3_INTERFACE:-}" "${UPLINK_INTERFACE:-}"; do
    [[ -n "$iface" ]] || continue

    if ip link show dev "$iface" >/dev/null 2>&1; then
        pass "Interface exists: $iface"
        ip -br addr show dev "$iface"
    else
        fail "Interface does not exist: $iface"
    fi
done

if [[ -n "${WP3_INTERFACE:-}" ]]; then
    if iw dev "$WP3_INTERFACE" info >/dev/null 2>&1; then
        pass "Wireless interface recognised by iw"

        PHY="$(iw dev "$WP3_INTERFACE" info 2>/dev/null |
            awk '/wiphy/ {print "phy" $2; exit}')"

        if [[ -n "$PHY" ]]; then
            printf 'Wireless PHY: %s\n' "$PHY"

            if iw phy "$PHY" info 2>/dev/null |
                grep -qE '^[[:space:]]+\*[[:space:]]+AP([[:space:]]|$)'; then
                pass "Wireless PHY advertises AP mode"
            else
                fail "AP mode not confirmed for $PHY"
            fi

            if iw phy "$PHY" info 2>/dev/null |
                grep -q 'interface combinations are not supported'; then
                warn "PHY does not advertise simultaneous interface combinations"
                warn "AP and managed operation may need to be sequential"
            fi
        else
            warn "Could not determine wireless PHY"
        fi
    else
        fail "Cannot inspect wireless interface using iw"
    fi
fi

# ------------------------------------------------------
# 5. Internet uplink
# ------------------------------------------------------

section "5. Internet Uplink Verification"

if [[ -n "${UPLINK_INTERFACE:-}" ]]; then
    ROUTE_OUTPUT="$(ip route get 1.1.1.1 2>&1 || true)"
    printf '%s\n' "$ROUTE_OUTPUT"

    if grep -q "dev ${UPLINK_INTERFACE}" <<< "$ROUTE_OUTPUT"; then
        pass "Preferred route to 1.1.1.1 uses $UPLINK_INTERFACE"
    else
        warn "Preferred route does not currently use $UPLINK_INTERFACE"
    fi

    if ip link show dev "$UPLINK_INTERFACE" 2>/dev/null |
        grep -q '<[^>]*UP'; then
        pass "Uplink interface is administratively UP"
    else
        warn "Uplink interface is not UP"
    fi
fi

# This checks routing only, not end-to-end internet reachability.
warn "Route lookup does not prove that external internet access works"

# ------------------------------------------------------
# 6. Network namespace support
# ------------------------------------------------------

section "6. Network Namespace Support"

if command -v ip >/dev/null 2>&1 &&
   ip netns list >/dev/null 2>&1; then
    pass "ip netns command is available"
    printf 'Existing namespaces:\n'
    ip netns list
else
    fail "Network namespace listing is unavailable"
fi

if [[ -d /run/netns ]]; then
    pass "/run/netns exists"
else
    warn "/run/netns does not currently exist"
fi

# ------------------------------------------------------
# 7. Docker preservation checks
# ------------------------------------------------------

section "7. Docker State and Network Verification"

if command -v docker >/dev/null 2>&1; then
    if docker info >/dev/null 2>&1; then
        pass "Docker daemon is accessible"

        DOCKER_COUNT="$(docker ps -q 2>/dev/null | wc -l)"
        printf 'Running containers: %s\n' "$DOCKER_COUNT"

        docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

        if [[ "$DOCKER_COUNT" -ge 3 ]]; then
            pass "At least three Docker containers are running"
        else
            warn "Fewer than three Docker containers are running"
        fi

        printf '\nDocker networks:\n'
        docker network ls
    else
        warn "Docker daemon is unavailable or inaccessible"
    fi
else
    warn "Docker command unavailable; Docker state not checked"
fi

# ------------------------------------------------------
# 8. BeEF port verification
# ------------------------------------------------------

section "8. BeEF Port Verification"

if command -v ss >/dev/null 2>&1; then
    BEEF_LISTENER="$(ss -lntp 2>/dev/null |
        grep -E '(^|[[:space:]])[^[:space:]]*:3000([[:space:]]|$)' || true)"

    if [[ -n "$BEEF_LISTENER" ]]; then
        printf '%s\n' "$BEEF_LISTENER"
        warn "Port 3000 has an active listener; verify BeEF binding and access policy"
    else
        warn "No TCP listener detected on port 3000"
    fi
fi

# ------------------------------------------------------
# 9. WP3 installation
# ------------------------------------------------------

section "9. WP3 Installation Verification"

WP3_BINARY="$(command -v wifipumpkin3 2>/dev/null || true)"
WP3_SOURCE="/usr/lib/python3/dist-packages/wifipumpkin3"

if [[ -n "$WP3_BINARY" ]]; then
    pass "WP3 executable found: $WP3_BINARY"
else
    fail "WP3 executable not found"
fi

if [[ -d "$WP3_SOURCE" ]]; then
    pass "WP3 Python source directory found"

    printf 'Source directory: %s\n' "$WP3_SOURCE"
else
    warn "Expected WP3 source directory not found"
fi

# ------------------------------------------------------
# 10. Global firewall operation audit
# ------------------------------------------------------

section "10. WP3 Global Firewall Operation Audit"

if [[ -d "$WP3_SOURCE" ]]; then
    FIREWALL_MATCHES="$(
        grep -RniE \
        'iptables.*(--flush|--delete-chain)|ip6tables.*(--flush|--delete-chain)' \
        "$WP3_SOURCE" \
        --include='*.py' 2>/dev/null || true
    )"

    if [[ -n "$FIREWALL_MATCHES" ]]; then
        warn "Potential global firewall operations found in WP3 source"
        printf '%s\n' "$FIREWALL_MATCHES" | head -n 20
        warn "Output limited to first 20 matches"
    else
        pass "No matching global flush/delete operations found by this scan"
    fi
else
    warn "Cannot scan WP3 source because its directory is unavailable"
fi

# ------------------------------------------------------
# 11. Subnet overlap verification
# ------------------------------------------------------


# ------------------------------------------------------
# 11. Subnet overlap verification
# ------------------------------------------------------

section "11. Subnet Overlap Verification"

if command -v python3 >/dev/null 2>&1 &&
   [[ -n "${WP3_SUBNET:-}" ]] &&
   [[ -n "${TRANSIT_SUBNET:-}" ]]; then

    DOCKER_CSV="$(IFS=,; echo "${DOCKER_SUBNETS[*]:-}")"
    LAN_CSV="$(IFS=,; echo "${PRIVATE_LAN_SUBNETS[*]:-}")"

    ACTUAL_DOCKER_CSV=""

    if command -v docker >/dev/null 2>&1 &&
       docker info >/dev/null 2>&1; then
        ACTUAL_DOCKER_CSV="$(
            docker network inspect $(docker network ls -q) \
                --format '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' \
                2>/dev/null | paste -sd, - || true
        )"
    fi

    WP3_SUBNET="$WP3_SUBNET" \
    TRANSIT_SUBNET="$TRANSIT_SUBNET" \
    DOCKER_CSV="$DOCKER_CSV" \
    LAN_CSV="$LAN_CSV" \
    ACTUAL_DOCKER_CSV="$ACTUAL_DOCKER_CSV" \
    python3 - <<'PY'
import ipaddress
import os
import sys

protected = {}

for label, env_name in (
    ("Configured Docker", "DOCKER_CSV"),
    ("Private LAN", "LAN_CSV"),
    ("Actual Docker", "ACTUAL_DOCKER_CSV"),
):
    for value in os.environ.get(env_name, "").split(","):
        value = value.strip()
        if value:
            try:
                network = ipaddress.ip_network(value, strict=False)
            except ValueError as exc:
                print(f"[FAIL] Invalid {label} subnet: {exc}")
                sys.exit(1)

            # Duplicate network declarations are expected.
            protected[str(network)] = network

test_networks = {}

for label, env_name in (
    ("WP3 AP", "WP3_SUBNET"),
    ("WP3 transit", "TRANSIT_SUBNET"),
):
    value = os.environ.get(env_name, "")
    try:
        test_networks[label] = ipaddress.ip_network(
            value, strict=False
        )
    except ValueError as exc:
        print(f"[FAIL] Invalid {label} subnet: {exc}")
        sys.exit(1)

errors = []

for test_label, test_net in test_networks.items():
    for protected_label, protected_net in protected.items():
        if test_net.overlaps(protected_net):
            print(
                f"[FAIL] {test_label} {test_net} overlaps "
                f"protected network {protected_net}"
            )
            errors.append((test_label, protected_label))

if errors:
    sys.exit(1)

print("[PASS] No overlap between WP3 networks and protected networks")

for label, network in test_networks.items():
    print(f"       {label}: {network}")

for network in sorted(protected):
    print(f"       Protected: {network}")
PY

    if [[ "$?" -eq 0 ]]; then
        pass "Subnet overlap verification passed"
    else
        fail "Subnet overlap verification failed"
    fi
else
    warn "Subnet overlap check skipped; required values unavailable"
fi


# ------------------------------------------------------
# 12. IPv6 and firewall visibility
# ------------------------------------------------------

section "12. IPv6 and Firewall Visibility"

if [[ -r /proc/sys/net/ipv6/conf/all/disable_ipv6 ]]; then
    printf 'Host IPv6 disabled flag: '
    cat /proc/sys/net/ipv6/conf/all/disable_ipv6
    warn "IPv6 isolation still needs explicit design and verification"
else
    warn "Could not inspect host IPv6 setting"
fi

if command -v iptables-save >/dev/null 2>&1; then
    if iptables-save >/dev/null 2>&1; then
        pass "Host IPv4 firewall rules are readable"
    else
        warn "Could not read host IPv4 firewall rules"
    fi
fi

if command -v ip6tables-save >/dev/null 2>&1; then
    if ip6tables-save >/dev/null 2>&1; then
        pass "Host IPv6 firewall rules are readable"
    else
        warn "Could not read host IPv6 firewall rules"
    fi
fi

# ------------------------------------------------------
# 13. Final report
# ------------------------------------------------------

section "13. Preflight Summary"

printf 'PASS : %s\n' "$PASS_COUNT"
printf 'WARN : %s\n' "$WARN_COUNT"
printf 'FAIL : %s\n' "$FAIL_COUNT"

printf '\n'

if [[ "$FAIL_COUNT" -eq 0 ]]; then
    printf '[RESULT] PRELIMINARY PREFLIGHT PASSED\n'
    printf 'Warnings must be reviewed before setup.\n'
else
    printf '[RESULT] PREFLIGHT FAILED\n'
    printf 'Resolve failures before considering setup.\n'
fi

printf '\n'
printf '%s\n' "IMPORTANT:"
printf '%s\n' "- This script is read-only."
printf '%s\n' "- No network configuration was changed."
printf '%s\n' "- No firewall rules were modified."
printf '%s\n' "- No Docker containers were stopped."
printf '%s\n' "- No WP3 service was started."
printf '%s\n' "======================================================"
