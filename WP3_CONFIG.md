# WiFi-Pumpkin3 — Configuration Changes and Script Ownership

**Environment:** Kali Linux on Raspberry Pi (`mypi`)  
**Project:** `/home/kali/wifipumpkin3`  
**Configuration:** `/root/.config/wifipumpkin3/config/app/config.ini`  
**Network namespace:** `wp3-ns`  
**AP interface:** `wlan2`  
**AP network:** `172.16.0.0/24`  
**AP gateway:** `172.16.0.1`

## 1. Purpose

This document records the current WP3 configuration and identifies which scripts are responsible for creating, modifying, or applying each setting.

The mapping distinguishes:

- **Modified:** A script writes or changes a persistent configuration value.
- **Applied:** A script installs a runtime setting, network configuration, or firewall rule.
- **Consumed:** WP3 reads a setting, but the reviewed helper does not modify it.
- **Not established:** The origin has not yet been verified.

A script that launches a service is not necessarily the script that configures that service.

## 2. Main configuration file

File:

`/root/.config/wifipumpkin3/config/app/config.ini`

### 2.1 DHCP address classes

| Section | Current range | Gateway | Netmask |
|---|---|---|---|
| Class-A-Address | 10.0.0.20–10.0.0.50 | 10.0.0.1 | 255.0.0.0 |
| Class-B-Address | 172.16.0.100–172.16.0.150 | 172.16.0.1 | 255.240.0.0 |
| Class-C-Address | 192.168.0.100–192.168.0.150 | 192.168.0.1 | 255.255.255.0 |

All three sections also contain broadcast and lease-duration settings.

**Script ownership**

`wp3-configure-dhcp.sh` does not modify these three address-class sections. Its reviewed Python update targets only `[dhcp]`.

The origin of the three address-class sections remains to be established.

### 2.2 Active `[dhcp]` section

| Field | Current value |
|---|---|
| classtype | C |
| subnet | 172.16.0.0 |
| netmask | 255.255.255.0 |
| broadcast | 172.16.0.255 |
| router | 172.16.0.1 |
| range | 172.16.0.100/172.16.0.150 |
| leasetimeDef | 600 |
| leasetimeMax | 7200 |

**Responsible script: `wp3-configure-dhcp.sh`**

Verified behaviour:
- Checks the supplied wireless interface.
- Checks for network and Docker subnet conflicts.
- Displays a DHCP configuration preview.
- Requires explicit `YES` confirmation.
- Creates a timestamped backup of `config.ini`.
- Updates only the `[dhcp]` section with the values shown above.

It does not configure the namespace, assign the AP IP, install firewall rules, or start WP3.

### 2.3 `[accesspoint]`

Selected current values:

| Field | Current value |
|---|---|
| ssid | WiFi Pumpkin 3 |
| bssid | BC:F6:85:03:36:5B |
| channel | 11 |
| ap_max_inactivity | 3600 |
| checkConnectionWifi | true |
| check_support_ap_mode | true |
| pydhcp_server | true |
| pydns_server | true |
| dhcpd_server | false |
| enable_hostapd_config | false |
| enable_security | false |
| interface | None |
| interface_net | @Invalid() |
| persistNetwokManager | true |
| status_ap | false |
| timer_update_info | 2000 |
| wpa_algorithms | TKIP |
| wpa_type | 2 |

The configured shared key is intentionally not reproduced in this document.

**Script ownership:** No reviewed helper has yet been shown to write these `[accesspoint]` fields.

`wp3-start.sh` supplies `-i wlan2` to the WP3 application. It does not edit the `interface` field in `config.ini`.

The `status_ap=false` entry is a stored configuration value; it is not, by itself, proof that the AP is stopped.

### 2.4 `[ap_mode]`

| Field | Current value |
|---|---|
| docker | false |
| karma | false |
| restapi | false |
| static | true |

**Script ownership:** No reviewed helper has been shown to modify this section.

The selected AP mode is consumed by WP3. The startup script launches WP3 but does not directly edit these values.

### 2.5 Module configuration

`[mitm_modules]`

| Module | Current value |
|---|---|
| responder | false |
| sniffkin3 | true |

`[proxy_plugins]`

| Plugin | Current value |
|---|---|
| captiveflask | false |
| evilqr3 | false |
| noproxy | false |
| phishkin3 | false |
| pumpkinproxy | true |

`[mana]`

| Field | Current value |
|---|---|
| enable_mana | true |
| mana_loud | false |
| mana_macl | false |
| mana_hostapd_path | ./plugins/bin/hostapd-mana/hostapd |

**Script ownership:** No reviewed helper has been shown to write these module-selection fields.

Do not interpret `[colors_log]` as module status. It contains log colour preferences, not enable/disable flags.

Also, `mana.enable_mana=true` and `ap_mode.karma=false` are separate settings and must not be treated as equivalent.

### 2.6 `[hostapd_config]`

| Field | Current value |
|---|---|
| hw_mode | g |
| ieee80211n | 1 |
| ignore_broadcast_ssid | 0 |
| skip_inactivity_poll | 1 |

**Script ownership:** No reviewed helper has been shown to modify these fields in `config.ini`.

The actual hostapd configuration-file generation and selection path still needs verification.

### 2.7 `[iptables]`

The configuration contains WP3 iptables command templates, including:
- FORWARD policy ACCEPT
- POSTROUTING MASQUERADE
- Forwarding rules between `$inet` and `$wlan`
- OUTPUT and INPUT acceptance rules
- iptables binary path `/usr/sbin/iptables`

**Script ownership:** The reviewed custom firewall helpers install their own namespace rules. They do not modify this `[iptables]` section.

WP3's own source code also contains iptables operations. Therefore, custom helper rules and WP3-generated rules must be documented separately.

### 2.8 Other configuration sections

- `[docker]`: hostapd executable path.
- `[karma]`: hostapd-WPE executable path.
- `[restapi]`: REST API hostapd executable path.
- `[static]`: static-mode hostapd executable path.
- `[settings]`: logging preferences.
- `[colors_log]`: module log colour preferences.
- `[rest_api_settings]`: API credentials and application secrets. These are deliberately excluded from this document.

No reviewed helper has yet been established as the writer of these fields.

## 3. dnsmasq configuration and ownership

Configuration file:

`/etc/wp3/dnsmasq.conf`

Runtime files:
- PID: `/run/wp3-dnsmasq.pid`
- Log: `/var/log/wp3-dnsmasq.log`

### Responsible script: `wp3-dnsmasq-start.sh`

Verified behaviour:
- Checks that `wp3-ns` exists.
- Checks that `wlan2` exists.
- Checks whether dnsmasq is already running.
- Launches dnsmasq inside `wp3-ns` using `/etc/wp3/dnsmasq.conf`.
- Supplies PID and log-file arguments.

**Important:** This script does not create or modify `/etc/wp3/dnsmasq.conf`. Its printed DHCP range and gateway/DNS messages are informational text, not dynamically read configuration values.

The script that originally creates or modifies `/etc/wp3/dnsmasq.conf` has not yet been identified.

## 4. Namespace and network configuration

Known runtime topology:

| Component | Address/value |
|---|---|
| Namespace | wp3-ns |
| AP interface | wlan2 |
| AP gateway | 172.16.0.1/24 |
| Client network | 172.16.0.0/24 |
| DHCP range | 172.16.0.100–172.16.0.150 |
| Host/namespace veth network | 169.254.250.0/30 |
| Namespace-side veth | 169.254.250.2 |
| Host-side veth | 169.254.250.1 |

These values describe the known topology. They should not all be attributed to one script without checking the exact commands.

The namespace and isolation setup/rollback scripts must be mapped separately to identify which script creates interfaces, assigns addresses, configures routes, and installs isolation rules.

## 5. Custom firewall helpers

These helpers apply runtime rules inside `wp3-ns`. They do not write persistent firewall configuration files.

### 5.1 `wp3-ap-services-firewall.sh`

Installs namespace INPUT permissions for:
- DHCP client requests arriving on `wlan2`.
- DNS UDP requests to `172.16.0.1`.
- DNS TCP requests to `172.16.0.1`.
- Established upstream UDP DNS replies from 1.1.1.1 and 8.8.8.8 arriving on the namespace veth.

Uses rule checks before insertion to avoid duplicates.

### 5.2 `wp3-captive-firewall.sh`

Creates the `WP3_CAPTIVE` NAT chain and redirects incoming TCP port 80 traffic on `wlan2` to port 8080.

This is HTTP redirection only. It does not configure HTTPS redirection or launch the portal.

### 5.3 `wp3-portal-firewall.sh`

Allows TCP port 8080 traffic from `172.16.0.0/24` arriving on `wlan2` to reach `172.16.0.1`.

It does not start the portal or create the HTTP redirection rule.

### 5.4 `wp3-internet-firewall.sh`

Creates and initializes the `WP3_AUTH` forwarding chain.

It:
- Flushes the chain.
- Adds destination-network DROP rules for the configured private, reserved, multicast and special-use address ranges.
- Adds a final DROP rule.
- Inserts a jump for AP-client forwarding.
- Allows established/related return traffic from the namespace veth to `wlan2`.

**Operational warning:** Because it flushes `WP3_AUTH`, rerunning it removes previously inserted client authorizations.

### 5.5 `wp3-authorize.sh`

Accepts a client IPv4 address and checks that it is within the configured DHCP client range.

It inserts a client-specific ACCEPT rule into `WP3_AUTH`.

It does not verify that the client currently holds that DHCP lease or that internet access is working. Its fixed insertion position also assumes the expected chain structure.

### Firewall ownership summary

| Runtime configuration | Responsible helper |
|---|---|
| DHCP/DNS INPUT permissions | wp3-ap-services-firewall.sh |
| HTTP captive redirect | wp3-captive-firewall.sh |
| Portal TCP 8080 access | wp3-portal-firewall.sh |
| Default-deny forwarding policy | wp3-internet-firewall.sh |
| Individual client authorization | wp3-authorize.sh |

## 6. Captive portal files and deployment

Project files:

- `wp3-portal.py` — deployed application.
- `wp3-portal.py.new` — candidate application.
- `wp3-portal-verify.py` — offline verification script.
- `portal/config/portal.ini` — portal configuration.
- `portal/templates/login.html` — login template.
- `portal/templates/success.html` — success template.
- `portal/static/style.css` — stylesheet.

### Candidate and deployed application ownership

The verification script is configured to load `wp3-portal.py.new`, not the deployed application.

The intended deployment process is:
1. Edit the candidate application and portal assets.
2. Run offline verification against `wp3-portal.py.new`.
3. Back up the deployed application.
4. Deploy the candidate as `wp3-portal.py`.
5. Compare SHA256 hashes.
6. Start the portal and validate it with a real test client.

`wp3-portal-start.sh` launches the deployed `wp3-portal.py` inside `wp3-ns`. It does not deploy the candidate or modify portal configuration.

`wp3-start.sh` also launches the deployed application directly.

### Verification scope

The offline verification script tests application loading, templates, CSRF behaviour, CSS delivery, captive probe redirection, client-network restrictions and success-page rendering.

These are offline tests. They do not prove a complete real-client DHCP, DNS, login or internet-access workflow.

## 7. Main startup script — configuration application, not configuration writer

`wp3-start.sh` is the runtime orchestrator.

It:
- Captures before/after baselines.
- Checks namespace and wireless interface availability.
- Starts WP3 in tmux.
- Waits for the operator to start the AP.
- Checks for `172.16.0.1/24` on `wlan2`.
- Starts dnsmasq if necessary.
- Applies the established INPUT rule.
- Calls the four firewall helpers.
- Starts the deployed Flask portal.
- Prints firewall and process status.

It does **not** directly modify `config.ini` or `/etc/wp3/dnsmasq.conf`.

It does call `wp3-internet-firewall.sh`, which resets the authorization chain. Therefore, starting WP3 again can clear client authorizations.

## 8. Script-to-configuration ownership matrix

| Configuration item | Responsible script/source | Type | Status |
|---|---|---|---|
| `[dhcp]` fields | wp3-configure-dhcp.sh | Persistent file modification | Verified |
| Class A/B/C DHCP sections | Not established | Persistent configuration | Pending |
| `[accesspoint]` fields | Not established | Persistent configuration | Pending |
| `[ap_mode]` fields | Not established | Persistent configuration | Pending |
| `[mitm_modules]` | Not established | Persistent configuration | Pending |
| `[proxy_plugins]` | Not established | Persistent configuration | Pending |
| `[mana]` | Not established | Persistent configuration | Pending |
| `[hostapd_config]` | Not established | Persistent configuration | Pending |
| `[iptables]` templates | Not established | Persistent configuration | Pending |
| `/etc/wp3/dnsmasq.conf` | Not established | Persistent configuration | Pending |
| dnsmasq process | wp3-dnsmasq-start.sh | Runtime launch | Verified |
| AP service firewall | wp3-ap-services-firewall.sh | Runtime rules | Verified |
| Captive HTTP redirect | wp3-captive-firewall.sh | Runtime rules | Verified |
| Portal access rule | wp3-portal-firewall.sh | Runtime rules | Verified |
| Client forwarding policy | wp3-internet-firewall.sh | Runtime rules | Verified |
| Client authorization | wp3-authorize.sh | Runtime rule | Verified |
| Portal application deployment | Candidate-to-live deployment procedure | File deployment | Verified workflow |
| Portal process | wp3-start.sh / wp3-portal-start.sh | Runtime launch | Verified |
| Namespace and veth setup | Isolation setup scripts | Runtime network configuration | Requires consolidated review |
| WP3 core modifications | Patch and modified source files | Application source modification | Requires final patch inventory |

## 9. Verification commands

Inspect the current persistent configuration:

```bash
sudo nl -ba /root/.config/wifipumpkin3/config/app/config.ini
```

Inspect dnsmasq configuration:

```bash
sudo nl -ba /etc/wp3/dnsmasq.conf
```

Inspect namespace interfaces and addresses:

```bash
sudo ip netns exec wp3-ns ip -br addr
```

Inspect namespace routes:

```bash
sudo ip netns exec wp3-ns ip route
```

Inspect namespace firewall rules:

```bash
sudo ip netns exec wp3-ns iptables -S INPUT
sudo ip netns exec wp3-ns iptables -S FORWARD
sudo ip netns exec wp3-ns iptables -S WP3_AUTH
sudo ip netns exec wp3-ns iptables -t nat -S
```

Inspect running services:

```bash
sudo ip netns exec wp3-ns pgrep -a dnsmasq
pgrep -a -f 'wifipumpkin3|hostapd|wp3-portal.py'
```

## 10. Outstanding provenance audit

The following must be inspected before declaring the configuration-to-script mapping complete:

1. Namespace and isolation setup/rollback scripts: exact interface, IP, route and firewall ownership.
2. Scripts that create or modify `/etc/wp3/dnsmasq.conf`.
3. Scripts that modify `[accesspoint]`, `[ap_mode]`, module settings, `[hostapd_config]` and `[iptables]`.
4. WP3 core patch: exact modified source files and the runtime configuration changes made by those code paths.
5. Baseline capture helper: exact state it records.

**Documentation rule:** Do not attribute a configuration field to a script merely because that script consumes the field, starts the related service, or checks its value. Record the writer separately from the runtime consumer.

**Completion criterion:** Every documented setting should have a verified current value, a verified writer or an explicit “not established” designation, and an appropriate verification command.
