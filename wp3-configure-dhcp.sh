#!/bin/bash
set -Eeuo pipefail

CONFIG="/root/.config/wifipumpkin3/config/app/config.ini"
IFACE="${1:-}"
TARGET="172.16.0.0/24"

if [[ $EUID -ne 0 ]]; then
    echo "[FAIL] Run with sudo."
    exit 1
fi

if [[ -z "$IFACE" ]]; then
    echo "Usage: sudo $0 <wireless-interface>"
    exit 1
fi

for cmd in ip iw nmcli python3 docker arp-scan; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "[FAIL] Required command missing: $cmd"
        exit 1
    }
done

ip link show "$IFACE" >/dev/null 2>&1 || {
    echo "[FAIL] Interface $IFACE does not exist."
    exit 1
}

iw dev "$IFACE" info >/dev/null 2>&1 || {
    echo "[FAIL] $IFACE is not a wireless interface."
    exit 1
}

[[ -f "$CONFIG" ]] || {
    echo "[FAIL] WP3 configuration not found."
    exit 1
}

echo
echo "=========================================="
echo " WiFi-Pumpkin3 DHCP Configuration Review"
echo "=========================================="
echo "Wireless interface : $IFACE"
echo "Proposed AP subnet : $TARGET"
echo "Configuration      : $CONFIG"

echo
echo "========== 1. Interface Details =========="
ip -br link show "$IFACE"
ip -4 -br address show "$IFACE"
iw dev "$IFACE" info | grep -E 'Interface|type|channel' || true

echo
echo "========== 2. Current Network Connections =========="
nmcli -f DEVICE,TYPE,STATE,CONNECTION device status

echo
echo "========== 3. Default Gateways =========="
ip -4 route show default

echo
echo "========== 4. Existing Route Conflict Check =========="

python3 - <<'PY'
import subprocess
import ipaddress
import sys

target = ipaddress.ip_network("172.16.0.0/24")

result = subprocess.run(
    ["ip", "-4", "route", "show"],
    capture_output=True, text=True
)

if result.returncode:
    print("[FAIL] Cannot read routing table.")
    sys.exit(1)

conflicts = []

for line in result.stdout.splitlines():
    try:
        route = ipaddress.ip_network(line.split()[0], strict=False)
        if target.overlaps(route):
            conflicts.append(line)
    except (ValueError, IndexError):
        pass

if conflicts:
    print("[FAIL] Route overlap detected:")
    for item in conflicts:
        print(" ", item)
    sys.exit(1)

print("[PASS] No current route overlaps 172.16.0.0/24.")
PY

echo
echo "========== 5. Docker Subnet Conflict Check =========="

python3 - <<'PY'
import subprocess
import ipaddress
import json
import sys

target = ipaddress.ip_network("172.16.0.0/24")

result = subprocess.run(
    ["docker", "network", "ls", "-q"],
    capture_output=True, text=True
)

if result.returncode:
    print("[FAIL] Cannot list Docker networks.")
    sys.exit(1)

checked = 0
conflicts = []

for network_id in result.stdout.split():
    inspect = subprocess.run(
        ["docker", "network", "inspect", network_id],
        capture_output=True, text=True
    )

    if inspect.returncode:
        print("[FAIL] Cannot inspect Docker network:", network_id)
        sys.exit(1)

    for network in json.loads(inspect.stdout):
        name = network.get("Name", network_id)

        for item in network.get("IPAM", {}).get("Config") or []:
            subnet = item.get("Subnet")
            if not subnet:
                continue

            existing = ipaddress.ip_network(subnet, strict=False)
            checked += 1
            print(f"[CHECK] {name}: {existing}")

            if target.overlaps(existing):
                conflicts.append((name, str(existing)))

if conflicts:
    print("[FAIL] Docker subnet conflict:")
    for name, subnet in conflicts:
        print(f"  {name}: {subnet}")
    sys.exit(1)

print(f"[PASS] Checked {checked} Docker subnet(s).")
print("[PASS] No Docker subnet overlap.")
PY

echo
echo "========== 6. Physical LAN ARP Scan =========="

echo "Scanning existing LAN interfaces without changing them."

LAN_INTERFACES=("eth0" "wlan0" "$IFACE")

for lan in "${LAN_INTERFACES[@]}"; do
    if ! ip link show "$lan" >/dev/null 2>&1; then
        continue
    fi

    STATE=$(cat "/sys/class/net/$lan/operstate" 2>/dev/null || echo unknown)

    if [[ "$STATE" != "up" ]]; then
        echo "[SKIP] $lan is not up."
        continue
    fi

    LAN_IP=$(ip -4 -o addr show dev "$lan" |
        awk '{print $4}' | head -n1)

    if [[ -z "$LAN_IP" ]]; then
        echo "[SKIP] No IPv4 address on $lan."
        continue
    fi

    echo
    echo "[SCAN] Interface: $lan | Address: $LAN_IP"

    arp-scan --interface="$lan" --localnet --retry=1 \
        --timeout=500 2>&1 || {
            echo "[WARNING] ARP scan failed on $lan."
        }
done

echo
echo "[INFO] ARP scans above cover each interface's existing LAN."
echo "[INFO] They do not prove that the isolated 172.16.0.0/24"
echo "[INFO] AP subnet is unused elsewhere."

echo
echo "========== 7. Proposed AP Subnet Neighbour Check =========="

ip neigh show | grep -E '172\.16\.0\.' || \
    echo "[INFO] No existing 172.16.0.x neighbour entries."

echo
echo "========== 8. DHCP Configuration Preview =========="

python3 - "$CONFIG" <<'PY'
import sys
import re
import ipaddress

path = sys.argv[1]

with open(path) as f:
    lines = f.readlines()

starts = [
    i for i, line in enumerate(lines)
    if re.match(r'^\s*\[dhcp\]\s*$', line)
]

if len(starts) != 1:
    print("[FAIL] Expected exactly one [dhcp] section.")
    sys.exit(1)

start = starts[0]
end = len(lines)

for i in range(start + 1, len(lines)):
    if re.match(r'^\s*\[[^\]]+\]\s*$', lines[i]):
        end = i
        break

updates = {
    "broadcast": "172.16.0.255",
    "classtype": "C",
    "leasetimeDef": "600",
    "leasetimeMax": "7200",
    "netmask": "255.255.255.0",
    "range": "172.16.0.100/172.16.0.150",
    "router": "172.16.0.1",
    "subnet": "172.16.0.0",
}

current = {}

for line in lines[start + 1:end]:
    stripped = line.strip()
    if not stripped or stripped.startswith(("#", ";")):
        continue
    if "=" not in stripped:
        continue

    key, value = stripped.split("=", 1)
    if key.strip() in updates:
        key = key.strip()
        if key in current:
            print("[FAIL] Duplicate DHCP key:", key)
            sys.exit(1)
        current[key] = value.strip()

print("Current configuration:")
for key in updates:
    print(f"  {key}={current.get(key, '<missing>')}")

print("\nProposed configuration:")
for key, value in updates.items():
    print(f"  {key}={value}")

print("\nDifferences:")
changes = False

for key, value in updates.items():
    old = current.get(key, "<missing>")
    if old != value:
        print(f"  {key}: {old} -> {value}")
        changes = True

if not changes:
    print("  No changes needed.")

network = ipaddress.ip_network("172.16.0.0/24")
gateway = ipaddress.ip_address("172.16.0.1")
first = ipaddress.ip_address("172.16.0.100")
last = ipaddress.ip_address("172.16.0.150")

if gateway not in network or gateway in (network.network_address,
                                          network.broadcast_address):
    print("[FAIL] Invalid gateway.")
    sys.exit(1)

if first not in network or last not in network or first > last:
    print("[FAIL] Invalid DHCP range.")
    sys.exit(1)

if first <= gateway <= last:
    print("[FAIL] Gateway is inside the DHCP pool.")
    sys.exit(1)

print("\n[PASS] DHCP values are internally consistent.")
PY

echo
echo "=========================================="
echo " Proposed Configuration Change"
echo "=========================================="
echo "Network       : 172.16.0.0/24"
echo "Gateway       : 172.16.0.1"
echo "DHCP range    : 172.16.0.100 - 172.16.0.150"
echo "Netmask       : 255.255.255.0"
echo "Broadcast     : 172.16.0.255"
echo
echo "Only [dhcp] will be changed."
echo "All other configuration sections remain untouched."
echo "No interface, route, firewall, or WP3 service changes."
echo

read -r -p "Apply these changes? Type YES to continue: " ANSWER

if [[ "$ANSWER" != "YES" ]]; then
    echo "[CANCELLED] No changes made."
    exit 0
fi

echo
echo "========== 9. Final Conflict Recheck =========="

python3 - <<'PY'
import subprocess
import ipaddress
import json
import sys

target = ipaddress.ip_network("172.16.0.0/24")

routes = subprocess.run(
    ["ip", "-4", "route", "show"],
    capture_output=True, text=True
)

if routes.returncode:
    print("[FAIL] Route recheck failed.")
    sys.exit(1)

for line in routes.stdout.splitlines():
    try:
        route = ipaddress.ip_network(line.split()[0], strict=False)
        if target.overlaps(route):
            print("[FAIL] Route conflict:", line)
            sys.exit(1)
    except (ValueError, IndexError):
        pass

ids = subprocess.run(
    ["docker", "network", "ls", "-q"],
    capture_output=True, text=True
)

if ids.returncode:
    print("[FAIL] Docker recheck failed.")
    sys.exit(1)

for network_id in ids.stdout.split():
    result = subprocess.run(
        ["docker", "network", "inspect", network_id],
        capture_output=True, text=True
    )

    if result.returncode:
        print("[FAIL] Docker inspect failed.")
        sys.exit(1)

    for network in json.loads(result.stdout):
        for item in network.get("IPAM", {}).get("Config") or []:
            subnet = item.get("Subnet")
            if subnet and target.overlaps(
                ipaddress.ip_network(subnet, strict=False)
            ):
                print("[FAIL] Docker conflict:", subnet)
                sys.exit(1)

print("[PASS] Route and Docker rechecks passed.")
PY

echo
echo "========== 10. Backup and Update =========="

BACKUP="${CONFIG}.backup-$(date +%Y%m%d-%H%M%S)"
cp -a "$CONFIG" "$BACKUP"

python3 - "$CONFIG" <<'PY'
import sys
import re
import os
import tempfile

path = sys.argv[1]

updates = {
    "broadcast": "172.16.0.255",
    "classtype": "C",
    "leasetimeDef": "600",
    "leasetimeMax": "7200",
    "netmask": "255.255.255.0",
    "range": "172.16.0.100/172.16.0.150",
    "router": "172.16.0.1",
    "subnet": "172.16.0.0",
}

with open(path) as f:
    lines = f.readlines()

sections = [
    (m.group(1), i)
    for i, line in enumerate(lines)
    if (m := re.match(r'^\s*\[([^\]]+)\]\s*$', line))
]

starts = [i for name, i in sections if name == "dhcp"]

if len(starts) != 1:
    print("[FAIL] Expected exactly one [dhcp] section.")
    sys.exit(1)

start = starts[0]
end = len(lines)

for name, i in sections:
    if i > start:
        end = i
        break

found = set()

for i in range(start + 1, end):
    match = re.match(
        r'^(\s*)([^#;=\s]+)(\s*=\s*)(.*?)(\r?\n)?$',
        lines[i]
    )

    if match and match.group(2) in updates:
        key = match.group(2)
        if key in found:
            print("[FAIL] Duplicate key:", key)
            sys.exit(1)

        lines[i] = (
            match.group(1) + key + match.group(3) +
            updates[key] + (match.group(5) or "\n")
        )
        found.add(key)

for key in updates:
    if key not in found:
        lines.insert(end, f"{key}={updates[key]}\n")
        end += 1

fd, temporary = tempfile.mkstemp(
    prefix=".wp3-config-",
    dir=os.path.dirname(path)
)

try:
    with os.fdopen(fd, "w") as f:
        f.writelines(lines)
        f.flush()
        os.fsync(f.fileno())

    os.chmod(temporary, os.stat(path).st_mode)
    os.replace(temporary, path)

except Exception:
    if os.path.exists(temporary):
        os.unlink(temporary)
    raise

print("[PASS] Updated only the [dhcp] section.")
PY

echo
echo "========== 11. Final DHCP Configuration =========="
sed -n '/^\[dhcp\]/,/^\[/p' "$CONFIG" | sed '$d'

echo
echo "[PASS] Configuration update completed."
echo "[BACKUP] $BACKUP"
echo "[INFO] WP3 has NOT been started."
