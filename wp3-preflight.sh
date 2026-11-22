#!/usr/bin/env bash

# WiFi-Pumpkin3 Pre-flight Verification
# Usage: sudo bash wp3-preflight.sh wlan2
# Read-only: does not modify network configuration.

set -u

IFACE="${1:-}"

if [[ -z "$IFACE" ]]; then
    read -rp "Enter wireless interface (e.g. wlan2): " IFACE
fi

if [[ $EUID -ne 0 ]]; then
    echo "Please run with sudo."
    exit 1
fi

if [[ ! "$IFACE" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
    echo "ERROR: Invalid interface name."
    exit 1
fi

PASS=0
WARN=0
FAIL=0

pass() { echo "[PASS] $*"; ((PASS+=1)); }
warn() { echo "[WARN] $*"; ((WARN+=1)); }
fail() { echo "[FAIL] $*"; ((FAIL+=1)); }
section() { echo; echo "========== $* =========="; }

get_conf() {
    local file="$1" section="$2" key="$3"
    [[ -f "$file" ]] || return 0
    awk -v s="[$section]" -v k="$key" '
        $0 == s { found=1; next }
        /^\[/ { found=0 }
        found && $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
            sub(/^[^=]*=/, "")
            sub(/[[:space:]]*[#;].*$/, "")
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            print
            exit
        }
    ' "$file"
}

WP3="/usr/lib/python3/dist-packages/wifipumpkin3"
BIN="/usr/bin/wifipumpkin3"
CONF="/root/.config/wifipumpkin3/config/app/config.ini"
PROXY="/root/.config/wifipumpkin3/config/app/pumpkinproxy.ini"
DNSZONE="/root/.config/wifipumpkin3/config/app/dns_hosts.ini"
HOSTAPD="/root/.config/wifipumpkin3/config/hostapd/hostapd.conf"

echo "=========================================="
echo " WiFi-Pumpkin3 Pre-flight Verification"
echo " Interface: $IFACE"
echo " Date: $(date)"
echo "=========================================="

# 1. Interface validation
section "1. Wireless Interface"

if ! ip link show "$IFACE" >/dev/null 2>&1; then
    fail "Interface $IFACE does not exist."
    echo "Cannot continue."
    exit 1
fi

if ! iw dev "$IFACE" info >/dev/null 2>&1; then
    fail "$IFACE is not recognized as a wireless interface."
    exit 1
fi

pass "Wireless interface exists."

iw dev "$IFACE" info

PHY=$(iw dev "$IFACE" info | awk '/wiphy/ {print "phy"$2}')
echo "Detected PHY: ${PHY:-Unknown}"

# 2. Driver
section "2. Wireless Driver"

if command -v ethtool >/dev/null 2>&1; then
    ethtool -i "$IFACE" 2>/dev/null || warn "Unable to read driver details."
else
    warn "ethtool is not installed."
fi

# 3. Wireless capabilities
section "3. Wireless Capabilities"

if [[ -n "${PHY:-}" ]]; then
    PHYINFO=$(iw phy "$PHY" info 2>/dev/null)

    if grep -qE '^[[:space:]]*\*[[:space:]]+AP$' <<< "$PHYINFO"; then
        pass "AP mode supported."
    else
        fail "AP mode not advertised by this PHY."
    fi

    if grep -qE '^[[:space:]]*\*[[:space:]]+managed$' <<< "$PHYINFO"; then
        pass "Managed mode supported."
    else
        warn "Managed mode not advertised."
    fi

    if grep -q "interface combinations are not supported" <<< "$PHYINFO"; then
        warn "Concurrent interface combinations are NOT supported."
    elif grep -q "valid interface combinations" <<< "$PHYINFO"; then
        pass "Interface combination information is available:"
        sed -n '/valid interface combinations/,+15p' <<< "$PHYINFO"
    else
        warn "Concurrent interface capability is unknown."
    fi
else
    fail "Could not identify PHY."
fi

# 4. Current network state
section "4. Current Network State"

ip -br addr show "$IFACE"
ip route

if command -v nmcli >/dev/null 2>&1; then
    nmcli -f DEVICE,TYPE,STATE,CONNECTION device status |
        awk -v d="$IFACE" 'NR==1 || $1==d'
else
    warn "NetworkManager CLI unavailable."
fi

# 5. WP3 installation
section "5. WiFi-Pumpkin3 Installation"

if command -v wifipumpkin3 >/dev/null 2>&1; then
    pass "WP3 executable found: $(command -v wifipumpkin3)"
else
    fail "WP3 executable not found."
fi

if dpkg-query -W -f='${Status} ${Version}\n' wifipumpkin3 2>/dev/null |
   grep -q "install ok installed"; then
    dpkg-query -W -f='WP3 package version: ${Version}\n' wifipumpkin3
    pass "WP3 package installed."
else
    warn "WP3 package status could not be verified through dpkg."
fi

if [[ -d "$WP3" ]]; then
    pass "WP3 Python package directory exists."
else
    warn "WP3 Python package directory not found at expected path."
fi

# 6. WP3 configuration
section "6. WP3 Configuration"

if [[ -f "$CONF" ]]; then
    pass "Main WP3 configuration found."

    echo "Configured interface: $(get_conf "$CONF" accesspoint interface)"
    echo "Configured SSID: $(get_conf "$CONF" accesspoint ssid)"
    echo "AP status: $(get_conf "$CONF" accesspoint status_ap)"
    echo "AP mode static: $(get_conf "$CONF" ap_mode static)"
    echo "Hostapd custom config enabled: $(get_conf "$CONF" accesspoint enable_hostapd_config)"
    echo "Python DHCP: $(get_conf "$CONF" accesspoint pydhcp_server)"
    echo "External DHCP: $(get_conf "$CONF" accesspoint dhcpd_server)"
    echo "Python DNS: $(get_conf "$CONF" accesspoint pydns_server)"
    echo "DNS verbose: $(get_conf "$CONF" accesspoint pydns_verbose)"
    echo "Configured DNS zone: $(get_conf "$CONF" accesspoint pydns_zone_file)"
else
    warn "Main WP3 configuration not found: $CONF"
fi

# 7. DHCP configuration
section "7. DHCP Configuration"

if [[ -f "$CONF" ]]; then
    for key in subnet router netmask broadcast range leasetimeDef leasetimeMax; do
        echo "$key: $(get_conf "$CONF" dhcp "$key")"
    done
else
    warn "Cannot inspect DHCP settings without main configuration."
fi

# 8. DNS configuration
section "8. DNS Configuration"

if [[ -f "$DNSZONE" ]]; then
    pass "DNS zone file exists."
    echo "Record count: $(grep -vcE '^[[:space:]]*(#|$)' "$DNSZONE")"
else
    warn "DNS zone file not found at expected path."
fi

if [[ -f "$WP3/core/packets/dnsserver.py" ]]; then
    grep -nE 'os.getenv\("PORT"|os.getenv\("UPSTREAM"|DNSServer\(' \
        "$WP3/core/packets/dnsserver.py"
else
    warn "DNS server source not found."
fi

# 9. Hostapd
section "9. Hostapd"

if command -v hostapd >/dev/null 2>&1; then
    pass "hostapd executable: $(command -v hostapd)"
else
    warn "hostapd executable not found in PATH."
fi

if [[ -f "$HOSTAPD" ]]; then
    pass "User hostapd configuration exists."
    grep -E '^(interface|ssid|channel|bssid)=' "$HOSTAPD" || true
else
    warn "User hostapd configuration not found."
fi

# 10. Proxy plugin safety
section "10. Proxy Plugin Configuration"

if [[ -f "$PROXY" ]]; then
    for key in downloadspoof js_inject html_inject beef; do
        value=$(get_conf "$PROXY" plugins "$key")
        echo "$key: ${value:-NOT SET}"
        if [[ "$value" == "true" ]]; then
            warn "$key is enabled. Review before lab use."
        fi
    done
else
    warn "Per-user proxy plugin configuration not found."
fi

# 11. Services and listening ports
section "11. Services and Listening Ports"

for port in 53 3000 6789 8080 1337; do
    if ss -lntu | grep -Eq "[:.]$port[[:space:]]"; then
        echo "Port $port:"
        ss -lntu | grep -E "[:.]$port[[:space:]]" || true
    else
        echo "Port $port: not listening"
    fi
done

# 12. Firewall and forwarding
section "12. Firewall Snapshot"

if command -v iptables-save >/dev/null 2>&1; then
    echo "iptables FORWARD policy:"
    iptables -S FORWARD 2>/dev/null | head -10
    echo "NAT POSTROUTING rules:"
    iptables -t nat -S POSTROUTING 2>/dev/null | head -15
else
    warn "iptables-save unavailable."
fi

echo "IPv4 forwarding: $(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo unknown)"

# 13. Final summary
section "13. Verification Summary"

echo "Interface: $IFACE"
echo "PHY: ${PHY:-Unknown}"
echo "PASS: $PASS"
echo "WARN: $WARN"
echo "FAIL: $FAIL"

if (( FAIL > 0 )); then
    echo "RESULT: NOT READY - resolve failures."
elif (( WARN > 0 )); then
    echo "RESULT: REVIEW REQUIRED - warnings need assessment."
else
    echo "RESULT: CHECKS PASSED - manual review still required."
fi

echo
echo "No network configuration was changed."
echo "No WP3 service was started."
