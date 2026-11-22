#!/usr/bin/env bash
# WP3 read-only baseline collector
# Writes reports only. Does not start/stop services or modify networking.

set -u

ROOT="$HOME/wifipumpkin3"
BASE="$ROOT/baseline"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$BASE/current-$STAMP"

mkdir -p "$OUT"
if command -v sudo >/dev/null 2>&1; then
    sudo -v || exit 1
else
    echo "sudo is required for complete collection."
    exit 1
fi

section() {
    local name="$1"
    shift
    {
        echo "============================================================"
        echo "SECTION: $name"
        echo "CAPTURED: $(date -Is)"
        echo "============================================================"
        sudo "$@"
        local rc=$?
        echo
        echo "COMMAND_EXIT_STATUS=$rc"
    } > "$OUT/$name.txt" 2>&1
}

shell_section() {
    local name="$1"
    local cmd="$2"
    {
        echo "============================================================"
        echo "SECTION: $name"
        echo "CAPTURED: $(date -Is)"
        echo "============================================================"
        bash -c "$cmd"
        local rc=$?
        echo
        echo "COMMAND_EXIT_STATUS=$rc"
    } > "$OUT/$name.txt" 2>&1
}

echo "WP3 baseline capture started: $(date -Is)" | tee "$OUT/README.txt"
echo "Host: $(hostname)" >> "$OUT/README.txt"
echo "Output: $OUT" >> "$OUT/README.txt"
echo "Read-only collection; report files are the only intended writes." >> "$OUT/README.txt"

section 01-system bash -c 'date -Is; hostnamectl 2>&1; uname -a; id; uptime'

section 02-host-interfaces bash -c '
ip -br link
echo; ip -br address
echo; ip -d link
echo; ip neigh show
'

section 03-host-routing bash -c '
ip route show table all
echo; ip rule show
echo; ip -6 route show table all
echo; ip -6 rule show
'

section 04-host-network-settings bash -c '
sysctl net.ipv4.ip_forward
sysctl net.ipv6.conf.all.forwarding
sysctl net.ipv6.conf.default.forwarding
sysctl net.ipv6.conf.all.disable_ipv6
'

section 05-namespaces bash -c '
ip netns list
echo
ip netns identify
'

section 06-wp3-namespace bash -c '
ip netns exec wp3-ns ip -br link
echo; ip netns exec wp3-ns ip -br address
echo; ip netns exec wp3-ns ip -d link
echo; ip netns exec wp3-ns ip route show table all
echo; ip netns exec wp3-ns ip rule show
echo; ip netns exec wp3-ns ip -6 address
echo; ip netns exec wp3-ns ip -6 route show table all
echo; ip netns exec wp3-ns ip neigh show
'

section 07-host-firewall bash -c '
for table in filter nat mangle raw security; do
    echo "######## iptables-save -t $table ########"
    iptables-save -t "$table" 2>&1
done
echo; iptables -L -n -v --line-numbers
echo; iptables -t nat -L -n -v --line-numbers
echo; ip6tables-save 2>&1
'

section 08-namespace-firewall bash -c '
for table in filter nat mangle raw security; do
    echo "######## namespace iptables-save -t $table ########"
    ip netns exec wp3-ns iptables-save -t "$table" 2>&1
done
echo; ip netns exec wp3-ns iptables -L -n -v --line-numbers
echo; ip netns exec wp3-ns iptables -t nat -L -n -v --line-numbers
echo; ip netns exec wp3-ns ip6tables-save 2>&1
'

section 09-processes bash -c '
ps -efww
echo
pgrep -a -f "wifipumpkin3|dnsmasq|wp3-portal|hostapd|flask" 2>&1
'

section 10-listening-sockets bash -c '
ss -lntup
echo; ss -lnup
'

section 11-wireless bash -c '
rfkill list
echo; iw dev
echo; iw phy
'

section 12-networkmanager bash -c '
nmcli general status
echo; nmcli device status
echo; nmcli connection show --active
'

section 13-docker bash -c '
docker ps -a
echo; docker network ls
echo; docker network inspect $(docker network ls -q) 2>&1
'

section 14-dnsmasq bash -c '
pgrep -a dnsmasq
echo; cat /etc/wp3/dnsmasq.conf
echo; ls -l /run/wp3-dnsmasq.pid /var/log/wp3-dnsmasq.log 2>&1
'

section 15-wp3-configuration bash -c '
CONFIG=/home/kali/.config/wifipumpkin3/config/app/config.ini
if [ -f "$CONFIG" ]; then
    echo "Active configuration: $CONFIG"
    cat "$CONFIG"
else
    echo "Active configuration not found: $CONFIG"
fi
'

section 16-isolation-state bash -c '
echo "State directory listing:"
find /var/lib/wp3-isolation -maxdepth 2 -type f -printf "%M %u:%g %s bytes %TY-%Tm-%Td %TH:%TM %p\n" 2>&1
echo
for f in /var/lib/wp3-isolation/*; do
    [ -f "$f" ] || continue
    echo "######## $f ########"
    cat "$f" 2>&1
done
'

# Capture relevant project files. Portal source is filtered to redact
# common secret-key/password/token assignments before being written.
{
    for f in \
        "$ROOT/wp3-isolation.conf" \
        "$ROOT/wp3-isolation-setup.sh" \
        "$ROOT/wp3-isolation-rollback.sh" \
        "$ROOT/wp3-ap-services-firewall.sh" \
        "$ROOT/wp3-internet-firewall.sh" \
        "$ROOT/wp3-authorize.sh" \
        "$ROOT/wp3-portal-start.sh" \
        "$ROOT/wp3-portal-firewall.sh" \
        "$ROOT/wp3-captive-firewall.sh" \
        "$ROOT/wp3-dnsmasq-start.sh" \
        "$ROOT/wp3-portal.py"
    do
        if sudo test -f "$f"; then
            echo
            echo "######## FILE: $f ########"
            if [[ "$f" == *wp3-portal.py ]]; then
                sudo sed -E \
                    -e 's/(SECRET_KEY[[:space:]]*=[[:space:]]*).*/\1<REDACTED>/' \
                    -e 's/(secret_key[[:space:]]*=[[:space:]]*).*/\1<REDACTED>/' \
                    -e 's/(PASSWORD[[:space:]]*=[[:space:]]*).*/\1<REDACTED>/' \
                    -e 's/(TOKEN[[:space:]]*=[[:space:]]*).*/\1<REDACTED>/' "$f"
            else
                sudo cat "$f"
            fi
        fi
    done
} > "$OUT/17-project-files.txt" 2>&1

section 18-project-file-metadata bash -c '
for f in /home/kali/wifipumpkin3/*.sh /home/kali/wifipumpkin3/*.py \
         /home/kali/wifipumpkin3/*.conf /etc/wp3/dnsmasq.conf; do
    [ -f "$f" ] || continue
    stat "$f"
    sha256sum "$f"
done
'

section 19-script-syntax bash -c '
for f in /home/kali/wifipumpkin3/*.sh; do
    [ -f "$f" ] || continue
    echo "######## $f ########"
    bash -n "$f"
    echo "bash -n exit status: $?"
done
'

section 20-service-status bash -c '
systemctl is-active NetworkManager
systemctl is-active hostapd
systemctl is-active wpa_supplicant
systemctl is-active docker
systemctl is-active dnsmasq
'

# Manifest of the completed report.
{
    echo "Baseline directory: $OUT"
    echo "Completed: $(date -Is)"
    echo
    find "$OUT" -maxdepth 1 -type f -printf '%f %s bytes\n' | sort
    echo
    echo "SHA256:"
    find "$OUT" -maxdepth 1 -type f ! -name MANIFEST.txt -print0 |
        sort -z | xargs -0 sha256sum
} > "$OUT/MANIFEST.txt"

echo
echo "Baseline capture completed."
echo "Report directory: $OUT"
echo "Review README.txt and MANIFEST.txt in that directory."
