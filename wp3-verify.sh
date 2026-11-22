#!/usr/bin/env bash

# WiFi-Pumpkin3 comprehensive read-only verification
# Does not modify firewall, network, services, or processes.

set +e

NS="wp3-ns"
AP="wlan2"
PORTAL_IP="172.16.0.1"
PORTAL_PORT="8080"
REPORT_DIR="$HOME/wifipumpkin3/reports"
TIMESTAMP=$(date '+%Y%m%d-%H%M%S')

mkdir -p "$REPORT_DIR"
REPORT="$REPORT_DIR/wp3-verify-$TIMESTAMP.txt"

exec > >(tee "$REPORT") 2>&1

PASS=0
WARN=0
FAIL=0

pass() { echo "[PASS] $*"; PASS=$((PASS+1)); }
warn() { echo "[WARN] $*"; WARN=$((WARN+1)); }
fail() { echo "[FAIL] $*"; FAIL=$((FAIL+1)); }

section() {
    echo
    echo "============================================================"
    echo "$*"
    echo "============================================================"
}

section "WP3 VERIFICATION REPORT"
echo "Date: $(date)"
echo "Host: $(hostname)"
echo "Namespace: $NS"
echo "Report: $REPORT"

section "1. WP3 APPLICATION"

if sudo tmux has-session -t wp3 2>/dev/null; then
    pass "WP3 tmux session exists"
else
    fail "WP3 tmux session missing"
fi

if sudo ip netns exec "$NS" pgrep -af 'wifipumpkin3' | grep -v grep; then
    pass "WP3 application process found"
else
    fail "WP3 application process not found"
fi

section "2. ACCESS POINT"

if sudo ip netns exec "$NS" ip link show "$AP" 2>/dev/null | grep -q 'UP'; then
    pass "$AP interface is UP"
else
    fail "$AP interface is not UP"
fi

if sudo ip netns exec "$NS" ip -4 addr show "$AP" | grep -q "$PORTAL_IP/24"; then
    pass "$AP has $PORTAL_IP/24"
else
    fail "Expected AP address $PORTAL_IP/24 missing"
fi

if sudo ip netns exec "$NS" pgrep -af hostapd | grep -v grep; then
    pass "hostapd process found"
else
    fail "hostapd process not found"
fi

section "3. DHCP AND DNS"

if sudo ip netns exec "$NS" pgrep -x dnsmasq >/dev/null 2>&1; then
    pass "dnsmasq process running"
else
    fail "dnsmasq process missing"
fi

if sudo ip netns exec "$NS" ss -lunp | grep -q ':53'; then
    pass "DNS UDP port 53 listening"
else
    fail "DNS UDP port 53 not listening"
fi

LEASE_FILE="/var/lib/misc/dnsmasq.leases"

if sudo test -r "$LEASE_FILE"; then
    echo "Current DHCP leases:"
    sudo cat "$LEASE_FILE"
    pass "DHCP lease file readable"
else
    warn "DHCP lease file unavailable"
fi

section "4. CAPTIVE PORTAL"

if sudo ip netns exec "$NS" ss -lntp | grep -q "$PORTAL_IP:$PORTAL_PORT"; then
    pass "Portal listening on $PORTAL_IP:$PORTAL_PORT"
else
    fail "Portal listener missing"
fi

section "5. FIREWALL INPUT"

sudo ip netns exec "$NS" iptables -S INPUT

if sudo ip netns exec "$NS" iptables -C INPUT \
    -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; then
    pass "INPUT established/related rule present"
else
    fail "INPUT established/related rule missing"
fi

section "6. FIREWALL FORWARD"

sudo ip netns exec "$NS" iptables -S FORWARD

if sudo ip netns exec "$NS" iptables -C FORWARD -i "$AP" -j WP3_AUTH 2>/dev/null; then
    pass "AP traffic routed through WP3_AUTH"
else
    fail "WP3_AUTH forwarding hook missing"
fi

section "7. AUTHORIZATION CHAIN"

sudo ip netns exec "$NS" iptables -L WP3_AUTH -n -v --line-numbers

if sudo ip netns exec "$NS" iptables -S WP3_AUTH | grep -q -- '-j DROP'; then
    pass "WP3_AUTH default DROP rule present"
else
    fail "WP3_AUTH default DROP rule missing"
fi

if sudo ip netns exec "$NS" iptables -S WP3_AUTH | grep -q -- '-j ACCEPT'; then
    pass "At least one authorised-client ACCEPT rule present"
else
    warn "No authorised-client ACCEPT rule found"
fi

section "8. NAT AND CAPTIVE REDIRECTION"

sudo ip netns exec "$NS" iptables -t nat -S

if sudo ip netns exec "$NS" iptables -t nat -C PREROUTING \
    -i "$AP" -p tcp --dport 80 -j WP3_CAPTIVE 2>/dev/null; then
    pass "HTTP traffic enters WP3_CAPTIVE"
else
    fail "Captive portal PREROUTING hook missing"
fi

if sudo ip netns exec "$NS" iptables -t nat -C WP3_CAPTIVE \
    -p tcp --dport 80 -j REDIRECT --to-ports "$PORTAL_PORT" 2>/dev/null; then
    pass "HTTP redirection to portal port $PORTAL_PORT present"
else
    fail "HTTP redirection rule missing"
fi

section "9. NAMESPACE INTERNET CONNECTIVITY"

if sudo ip netns exec "$NS" ping -c 3 -W 2 1.1.1.1; then
    pass "Namespace internet connectivity"
else
    fail "Namespace cannot reach 1.1.1.1"
fi

section "10. SYSTEM RESOURCES"

echo "CPU and load:"
top -b -n 1 | head -5

echo
echo "Memory:"
free -h

echo
echo "Disk:"
df -h /

section "11. LOG ERRORS"

for LOG in /var/log/wp3/wifipumpkin3.log /var/log/wp3/portal.log; do
    echo
    echo "Log: $LOG"

    if sudo test -r "$LOG"; then
        sudo tail -n 15 "$LOG"
    else
        warn "Log unavailable: $LOG"
    fi
done

section "FINAL SUMMARY"

echo "PASS: $PASS"
echo "WARN: $WARN"
echo "FAIL: $FAIL"
echo
echo "Full report saved to:"
echo "$REPORT"

if [ "$FAIL" -gt 0 ]; then
    echo "Overall result: FAIL - investigate failed checks"
elif [ "$WARN" -gt 0 ]; then
    echo "Overall result: WARN - review warnings"
else
    echo "Overall result: PASS"
fi

echo "============================================================"
