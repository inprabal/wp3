#!/usr/bin/env bash
#
# wp3-audit.sh
# Read-only preflight and configuration audit for WiFi-Pumpkin3 on Kali/Debian.
#
# This script does NOT start/stop WP3, change network configuration, modify
# firewall rules, edit WP3 configuration, or stop/restart Docker containers.
#
# Example:
#   sudo ./wp3-audit.sh \
#     --iface wlan2 \
#     --ap-cidr 172.16.0.0/24 \
#     --config /root/.config/wifipumpkin3/config/app/config.ini
#
set -u
export LC_ALL=C

IFACE="wlan2"
AP_CIDR="172.16.0.0/24"
CONFIG="/root/.config/wifipumpkin3/config/app/config.ini"
PROXY_CONFIG="/root/.config/wifipumpkin3/config/app/pumpkinproxy.ini"
WP3_ROOT="/usr/lib/python3/dist-packages/wifipumpkin3"
OUTDIR=""

usage() {
  cat <<'USAGE'
Usage: sudo ./wp3-audit.sh [options]

Options:
  --iface NAME       Wireless interface intended for the WP3 AP (default: wlan2)
  --ap-cidr CIDR     Planned isolated AP subnet (default: 172.16.0.0/24)
  --config PATH      WP3 app config.ini path
  --proxy-config PATH
                     WP3 pumpkinproxy.ini path
  --wp3-root PATH    Installed WP3 Python package directory
  --outdir PATH      Optional directory for a text report (directory must exist)
  -h, --help         Show this help

Read-only audit. No system/network/configuration changes are made.
USAGE
}

while (($#)); do
  case "$1" in
    --iface) [[ $# -ge 2 ]] || { echo "Missing value for --iface"; exit 2; }; IFACE="$2"; shift 2 ;;
    --ap-cidr) [[ $# -ge 2 ]] || { echo "Missing value for --ap-cidr"; exit 2; }; AP_CIDR="$2"; shift 2 ;;
    --config) [[ $# -ge 2 ]] || { echo "Missing value for --config"; exit 2; }; CONFIG="$2"; shift 2 ;;
    --proxy-config) [[ $# -ge 2 ]] || { echo "Missing value for --proxy-config"; exit 2; }; PROXY_CONFIG="$2"; shift 2 ;;
    --wp3-root) [[ $# -ge 2 ]] || { echo "Missing value for --wp3-root"; exit 2; }; WP3_ROOT="$2"; shift 2 ;;
    --outdir) [[ $# -ge 2 ]] || { echo "Missing value for --outdir"; exit 2; }; OUTDIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 2 ;;
  esac
done

if [[ -n "$OUTDIR" && ! -d "$OUTDIR" ]]; then
  echo "ERROR: --outdir must already exist: $OUTDIR" >&2
  exit 2
fi

REPORT=""
if [[ -n "$OUTDIR" ]]; then
  REPORT="$OUTDIR/wp3-audit-$(hostname)-$(date +%Y%m%d-%H%M%S).txt"
  # tee writes only the explicitly requested report file.
  exec > >(tee "$REPORT") 2>&1
fi

PASS=0
WARN=0
FAIL=0
INFO=0
PASS_ITEMS=()
WARN_ITEMS=()
FAIL_ITEMS=()
INFO_ITEMS=()

section() { printf '\n\n========== %s ==========\n' "$1"; }
info() { printf '[INFO] %s\n' "$*"; INFO=$((INFO+1)); INFO_ITEMS+=("$*"); }
pass() { printf '[PASS] %s\n' "$*"; PASS=$((PASS+1)); PASS_ITEMS+=("$*"); }
warn() { printf '[WARN] %s\n' "$*"; WARN=$((WARN+1)); WARN_ITEMS+=("$*"); }
fail() { printf '[FAIL] %s\n' "$*"; FAIL=$((FAIL+1)); FAIL_ITEMS+=("$*"); }
have() { command -v "$1" >/dev/null 2>&1; }

read_ini() {
  local file="$1" section_name="$2" key="$3"
  [[ -r "$file" ]] || return 1
  awk -v sec="[$section_name]" -v key="$key" '
    BEGIN { insec=0 }
    /^\[/ { insec=($0==sec); next }
    insec && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      sub(/^[^=]*=/,""); gsub(/^[[:space:]]+|[[:space:]]+$/,""); print; exit
    }
  ' "$file"
}

echo "WiFi-Pumpkin3 READ-ONLY AUDIT"
echo "Date:       $(date -Is 2>/dev/null || date)"
echo "Host:       $(hostname)"
echo "Interface:  $IFACE"
echo "AP subnet:  $AP_CIDR"
echo "Config:     $CONFIG"
echo "WP3 root:   $WP3_ROOT"
echo "Run as:     $(id -un) (UID $(id -u))"
echo "NOTE: This script does not change system state."

section "1. SYSTEM"
if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  info "OS: ${PRETTY_NAME:-unknown}"
fi
info "Kernel: $(uname -r)"
info "Architecture: $(uname -m)"
if [[ $EUID -eq 0 ]]; then pass "Running as root; privileged read-only checks available"
else warn "Not running as root; some interface/firewall details may be unavailable. Use sudo for a fuller audit"
fi
if have wifipumpkin3; then
  info "WP3 executable: $(command -v wifipumpkin3)"
  wifipumpkin3 --version 2>&1 | head -n 2 || true
else
  warn "wifipumpkin3 executable not found in PATH"
fi
if [[ -d "$WP3_ROOT" ]]; then pass "WP3 Python package directory exists"
else warn "WP3 Python package directory not found: $WP3_ROOT"
fi

section "2. WIRELESS INTERFACE AND DRIVER"
if have ip; then
  ip -br link show "$IFACE" 2>&1 || warn "Interface $IFACE not found by ip"
  ip -br addr show "$IFACE" 2>&1 || true
else
  fail "ip command unavailable"
fi

if have iw; then
  iw dev "$IFACE" info 2>&1 || warn "iw could not read $IFACE"
  PHY="$(iw dev "$IFACE" info 2>/dev/null | awk '/wiphy/ {print "phy"$2; exit}')"
  if [[ -n "${PHY:-}" ]]; then
    info "Wireless PHY: $PHY"
    iw phy "$PHY" info 2>/dev/null | grep -A 12 -m 1 "Supported interface modes" || true
    iw phy "$PHY" info 2>/dev/null | grep -A 5 -m 1 "valid interface combinations" || \
      iw phy "$PHY" info 2>/dev/null | grep -A 3 -m 1 "interface combinations" || true
    if iw phy "$PHY" info 2>/dev/null | grep -q "interface combinations are not supported"; then
      warn "$PHY reports that interface combinations are not supported; do not assume simultaneous AP+managed operation"
    fi
  else
    warn "Could not map $IFACE to a PHY"
  fi
else
  warn "iw command unavailable"
fi

if have ethtool; then
  ethtool -i "$IFACE" 2>&1 || info "ethtool driver details unavailable for $IFACE"
fi

if have nmcli; then
  nmcli -f DEVICE,TYPE,STATE,CONNECTION device status 2>&1 || true
else
  info "nmcli unavailable"
fi

section "3. IP ADDRESSES AND ROUTING"
if have ip; then
  ip -br addr
  echo "--- IPv4 routes ---"
  ip -4 route show
  echo "--- IPv6 routes ---"
  ip -6 route show
  echo "--- Route to planned AP subnet ---"
  ip route get "${AP_CIDR%/*}" 2>&1 || true
else
  warn "Cannot inspect routes: ip command unavailable"
fi

section "4. PLANNED AP SUBNET VALIDATION"
info "Planned AP CIDR: $AP_CIDR"
if have python3; then
  python3 - "$AP_CIDR" <<'PY'
import ipaddress, sys
try:
    net = ipaddress.ip_network(sys.argv[1], strict=False)
    print(f"[INFO] Normalized network: {net}")
    print(f"[INFO] Network address:   {net.network_address}")
    print(f"[INFO] Broadcast address: {net.broadcast_address}")
    print(f"[INFO] Usable hosts:      {net.num_addresses - (2 if net.version == 4 and net.prefixlen < 31 else 0)}")
    if net.version != 4:
        print("[WARN] WP3 AP configuration here is expected to use IPv4")
except ValueError as exc:
    print(f"[FAIL] Invalid CIDR: {exc}")
    sys.exit(1)
PY
else
  warn "python3 unavailable; cannot validate CIDR syntax"
fi
warn "CIDR syntax is checked, but this version does not automatically calculate overlap with every host route or Docker network. Compare the displayed subnets manually; an unused subnet elsewhere on the LAN is not proven."

section "5. DOCKER SERVICES AND NETWORKS"
if have docker; then
  echo "--- Running containers ---"
  docker ps --no-trunc 2>&1 || warn "docker ps failed (check Docker access/daemon)"
  echo "--- Docker networks ---"
  docker network ls 2>&1 || true
  echo "--- Docker network names, subnets and gateways ---"
  docker network inspect $(docker network ls -q 2>/dev/null) \
    --format '{{.Name}}: {{range .IPAM.Config}}{{.Subnet}} gateway={{.Gateway}} {{end}}' 2>&1 || true
else
  warn "Docker CLI not installed"
fi

section "6. FIREWALL STATE (READ-ONLY)"
if have iptables; then
  echo "--- IPv4 filter/NAT policies and WP3/Docker chain references ---"
  iptables -S 2>&1 | grep -E '^(\\*|:|-[PN]|-A (FORWARD|INPUT|OUTPUT)|-A .*DOCKER|^-N (DOCKER|WP3))' || true
  echo "--- IPv4 NAT table ---"
  iptables -t nat -S 2>&1 || true
else
  warn "iptables command unavailable"
fi
if have ip6tables; then
  echo "--- IPv6 filter policies/chains ---"
  ip6tables -S 2>&1 | grep -E '^(\\*|:|-[PN]|-N (DOCKER|WP3))' || true
else
  info "ip6tables command unavailable"
fi
for f in /root/wp3-iptables-before.txt /root/wp3-ip6tables-before.txt; do
  if [[ -s "$f" ]]; then pass "Existing firewall snapshot found: $f"
  else info "No non-empty snapshot at $f"
  fi
done
warn "This is a display/audit only. It does not save, restore, flush or alter firewall rules."

section "7. WP3 APP CONFIGURATION"
if [[ -r "$CONFIG" ]]; then
  pass "WP3 app config is readable"
  echo "--- Selected [accesspoint] values ---"
  for key in interface ssid channel status_ap enable_security check_support_ap_mode persistNetwokManager pydhcp_server pydns_server dhcpd_server; do
    val="$(read_ini "$CONFIG" accesspoint "$key" 2>/dev/null || true)"
    printf '%-28s %s\n' "$key" "${val:-<not found>}"
  done
  echo "--- Selected [dhcp] values ---"
  for key in classtype subnet netmask broadcast router range leasetimeDef leasetimeMax; do
    val="$(read_ini "$CONFIG" dhcp "$key" 2>/dev/null || true)"
    printf '%-28s %s\n' "$key" "${val:-<not found>}"
  done
  DHCP_SUBNET="$(read_ini "$CONFIG" dhcp subnet 2>/dev/null || true)"
  DHCP_MASK="$(read_ini "$CONFIG" dhcp netmask 2>/dev/null || true)"
  DHCP_ROUTER="$(read_ini "$CONFIG" dhcp router 2>/dev/null || true)"
  if [[ -n "$DHCP_SUBNET" && -n "$DHCP_MASK" && -n "$DHCP_ROUTER" ]]; then
    info "DHCP subnet/router/netmask are populated"
  else
    warn "One or more expected [dhcp] network values are missing"
  fi
  AP_STATUS="$(read_ini "$CONFIG" accesspoint status_ap 2>/dev/null || true)"
  [[ "$AP_STATUS" == "false" || "$AP_STATUS" == "False" || "$AP_STATUS" == "0" || -z "$AP_STATUS" ]] \
    && pass "Config does not indicate AP status=true" \
    || warn "Config reports status_ap=$AP_STATUS; verify whether WP3 is active before any further work"
else
  fail "WP3 app config is not readable: $CONFIG"
fi

section "8. WP3 PROXY / INJECTION CONFIGURATION"
if [[ -r "$PROXY_CONFIG" ]]; then
  pass "WP3 proxy config is readable"
  for key in downloadspoof js_inject html_inject beef no-cache; do
    val="$(read_ini "$PROXY_CONFIG" plugins "$key" 2>/dev/null || true)"
    printf '%-20s %s\n' "$key" "${val:-<not found>}"
    case "$key:$val" in
      *:true|*:True|*:1) warn "Plugin flag $key is enabled; review before an isolated AP test" ;;
    esac
  done
  info "Configured URLs/paths are not proof of active injection; plugin enable flags and runtime state matter."
else
  warn "WP3 proxy config is not readable: $PROXY_CONFIG"
fi

section "9. SOURCE-CODE AUDIT LOCATORS (NO CODE EXECUTION)"
if [[ -d "$WP3_ROOT" ]]; then
  echo "--- Firewall flush/delete call sites ---"
  grep -RniE 'iptables.*(flush|delete-chain)|--flush|--delete-chain' \
    "$WP3_ROOT/core" --include='*.py' 2>/dev/null | head -n 80 || true
  echo "--- DNS/DHCP thread lifecycle references ---"
  grep -RniE 'DNSServerThread|DHCPThread|def Start|def Stop|def shutdown|def stop|\\.start\\(\\)' \
    "$WP3_ROOT/core/servers/dns" "$WP3_ROOT/core/servers/dhcp" \
    "$WP3_ROOT/core/packets/dnsserver.py" "$WP3_ROOT/core/packets/dhcpserver.py" \
    "$WP3_ROOT/core/common/console.py" 2>/dev/null | head -n 120 || true
  echo "--- Proxy redirect and cleanup references ---"
  grep -RniE 'PREROUTING|REDIRECT|proxy_port|ClearRules|unset_Rules|def shutdown|def Stop' \
    "$WP3_ROOT/core/servers/proxy" "$WP3_ROOT/core/controllers" \
    --include='*.py' 2>/dev/null | head -n 120 || true
else
  warn "WP3 source directory unavailable; source audit locators skipped"
fi
info "Grep output is a locator list, not proof of complete runtime behaviour. Review the referenced functions and call paths."

section "10. DETAILED SUMMARY AND READINESS"
printf 'Host: %s | Interface: %s | Planned AP subnet: %s\n' "$(hostname)" "$IFACE" "$AP_CIDR"
printf 'Totals: PASS=%d | WARN=%d | FAIL=%d | INFO=%d\n' "$PASS" "$WARN" "$FAIL" "$INFO"

print_items() {
  local label="$1"; shift
  local -a items=("$@")
  printf '\n--- %s (%d) ---\n' "$label" "${#items[@]}"
  if ((${#items[@]} == 0)); then echo 'None recorded.'; return; fi
  local i=1
  for item in "${items[@]}"; do printf '%2d. %s\n' "$i" "$item"; i=$((i+1)); done
}
print_items 'PASS - verified checks' "${PASS_ITEMS[@]}"
print_items 'WARN - attention required / limitations' "${WARN_ITEMS[@]}"
print_items 'FAIL - failed checks' "${FAIL_ITEMS[@]}"
print_items 'INFO - observations' "${INFO_ITEMS[@]}"

cat <<'ASSESSMENT'

--- INTERPRETATION ---
- PASS means the specific check reported success; it does not certify WP3 startup safety.
- WARN means a risk, limitation, missing item, or unverified condition needs review.
- FAIL means a required check failed or a required resource/configuration was unavailable.
- INFO is contextual output and is not itself a pass/fail result.

--- KNOWN SOURCE-AUDIT RISKS (based on reviewed WP3 source in this investigation) ---
1. Static AP configuration path contains global iptables filter/NAT flush and chain deletion.
   Impact: can remove Docker-managed firewall rules and disrupt published container ports/networking.
2. PumpkinProxy registers a PREROUTING TCP/80 REDIRECT without an ingress-interface restriction.
   Impact: rule scope is broader than wlan2; do not enable for the initial isolated AP test.
3. Proxy base shutdown stops its process reactor but does not visibly call ClearRules() for
   rules registered via add_default_rules(); default-rule cleanup is not established.
4. DHCP Stop() calls shutdown(), reactor.stop(), then clears client tracking; complete process
   termination and exception-safe cleanup have not been demonstrated.
5. DNS stop path needs final verification against the concrete UDP/TCP server stop implementation.
6. wlan2 PHY reports no supported interface combinations; do not assume simultaneous
   managed-client and AP operation on that adapter.

These are source-review findings from the code paths inspected in this investigation, not
runtime test results from this script. Recheck source locations after WP3 package upgrades.

--- OVERALL READINESS ---
NOT APPROVED FOR WP3 STARTUP based on the currently documented global firewall cleanup risk.
Do not proceed until a Docker-preserving isolation/rollback design is reviewed and tested,
and DNS/DHCP/proxy cleanup paths are resolved or explicitly excluded from the test.
ASSESSMENT

if [[ -n "$REPORT" ]]; then
  echo "[REPORT] $REPORT"
fi
cat <<'ENDNOTE'

SAFETY NOTES
- This script is read-only except when --outdir is explicitly supplied to write a report.
- It does not start WiFi-Pumpkin3 or hostapd.
- It does not disconnect or reconfigure any wireless interface.
- It does not change IP addresses, routes, DNS, DHCP or NetworkManager.
- It does not flush, add, delete, save or restore firewall rules.
- It does not stop, restart or modify Docker containers or networks.
- A clean report does not prove that WP3 is safe to start; source-code review and a
  tested rollback plan are still required.
ENDNOTE

if (( FAIL > 0 )); then exit 1
elif (( WARN > 0 )); then exit 2
else exit 0
fi
