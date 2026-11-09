# UniFi UCG Ultra setup

This is the maintained reference for the home gateway, networks and access policies configured
manually in UniFi. Update it whenever changing VLANs, Wi-Fi settings, firewall exceptions
or discovery settings. Physical port assignments are not tracked here. Record the configuration actually applied; keep
proposed changes and unverified details in the maintenance section until confirmed.

Do not add passwords, pairing codes, serial numbers, MAC addresses or actual SSID names.
Device names in examples should be generic. Internal subnets and service ports are retained
because they are useful for operating the network.

## Networks

| Network | VLAN | Subnet            | Gateway        | Zone     |
|---------|------|-------------------|----------------|----------|
| Default | 1    | `192.168.1.0/24`  | `192.168.1.1`  | Internal |
| IoT     | 20   | `192.168.20.0/24` | `192.168.20.1` | IoT      |

Default is the trusted network. IoT devices have restricted access to trusted clients and
router services. Internet access is blocked unless explicitly allowed for a device or service.

### IoT DHCP

- Server enabled, pool `192.168.20.6–192.168.20.254`.
- Automatic default gateway and DNS: the UCG at `192.168.20.1`.
- DHCP guarding permits `192.168.20.1` as the DHCP server.
- IPv6 disabled.
- Reserve addresses for devices referenced by IP in firewall rules or HA integrations.

### IoT Wi-Fi

- Dedicated IoT SSID, broadcast by all APs, **2.4 GHz only**.
- WPA2, PMF disabled.
- Fast Roaming, BSS Transition and band steering disabled.
- Client Device Isolation enabled and confirmed restored after pairing troubleshooting.
- Other tuning options left at defaults.

The trusted SSID remains on Default. On Macs, a fixed private Wi-Fi address is stable per SSID;
rotating addresses can invalidate UniFi Device selections. A Mac joining IoT has a separate
identity from its connection to the trusted SSID.

## Firewall

Open Settings and search for **Zone Matrix**. **Ordering is per directed zone pair**: select
the relevant matrix cell to inspect or reorder rules. The combined list can interleave rules
from different pairs and should not be used to compare their execution order.

Put exceptions above the corresponding block. Enable **Auto Allow Return Traffic** on
Internal → IoT allows. External already has built-in return traffic handling, so that option
is disabled for internet exceptions. Source ports remain Any: clients normally choose a
temporary source port, while the destination port identifies the service being accessed.

### IoT → External

| Source       | Protocol / destination port | Action                      |
|--------------|-----------------------------|-----------------------------|
| Kindle       | Any                         | Allow                       |
| Roborock     | Any                         | Allow                       |
| Nest Protect | Any                         | Allow                       |
| Eufy         | Any                         | Allow                       |
| Tesla        | Any                         | Allow                       |
| All IoT      | UDP 123 (NTP)               | Allow                       |
| All IoT      | Any                         | Block: `IoT block internet` |

All exceptions precede the internet block, which precedes the built-in allow. Their relative
order does not matter when they do not conflict. Internet exceptions do not grant access to
Internal or gateway services.

Devices without an internet exception (the shared NTP allowance still applies):

- **SlimmeLezer:** local only, Telnet (TCP 23) for HA DSMR.
- **Tado:** local only, HomeKit.

### IoT → Gateway

| Source      | Destination   | Protocol / destination port | Action                     |
|-------------|---------------|-----------------------------|----------------------------|
| All IoT     | Gateway       | TCP/UDP 53                  | Allow DNS                  |
| All IoT     | Gateway       | IPv4 UDP 67                 | Allow DHCP                 |
| All IoT     | Gateway       | IPv4 ICMP Echo Request      | Allow connectivity checks  |
| Tado bridge | `224.0.0.251` | IPv4 UDP 5353               | Allow mDNS                 |
| All IoT     | Gateway       | Any other traffic           | Block: `IoT block gateway` |

Gateway means services on the router itself, rather than traffic routed through it.
Destination Any in this zone includes the router's addresses on its different networks.
The block protects services such as router administration while preserving the exceptions.

The ICMP exception stopped repeated blocked events from the SlimmeLezer to `192.168.20.1`.
Those events did not expose ICMP type/code. The configured exception allows **Echo Request only**.

### Internal → IoT

| Source                         | Destination                 | Protocol / destination port | Action                                |
|--------------------------------|-----------------------------|-----------------------------|---------------------------------------|
| Four designated Mac interfaces | Any IoT                     | TCP 80, 443                 | Allow web interfaces + return traffic |
| pi501 and pi502                | SlimmeLezer `192.168.20.40` | TCP 23                      | Allow DSMR + return traffic           |
| pi501 and pi502                | Tado `192.168.20.60`        | TCP 80                      | Allow HomeKit + return traffic        |
| All other Internal traffic     | IoT                         | Any                         | Block                                 |

Mac interfaces are selected directly using UniFi's **Device** selector: three Wi-Fi interfaces
and one Ethernet interface. Both Pis are selected for the HA rules.

Tado advertises **TCP 80** for HomeKit. The HA → Tado rule is restricted to that destination
port, and operation has been verified.

### Other directions

- IoT → Internal blocks new connections. Automatic return rules permit replies to authorized
  Internal connections.
- IoT → VPN, Hotspot and DMZ are blocked, as are connections from those zones to IoT.
- Gateway → IoT retains the built-in allow.
- No MQTT or Duux-specific openings or DNS changes are part of this setup.

## HomeKit discovery

HA on Default needs to discover the Tado HomeKit bridge on IoT. Since mDNS normally stays
within one VLAN, the gateway proxy relays HomeKit discovery between these networks.

UniFi **Settings → Networks → Gateway mDNS Proxy**:

- Mode: **Custom**.
- VLAN scope: **Default (1)** and **IoT (20)**.
- Service scope: **Specific → HomeKit only** (`_hap._tcp`).

The separate HA → Tado TCP rule allows the actual connection.

`224.0.0.251` is the IPv4 mDNS multicast destination, using UDP 5353. The Tado → Gateway
exception must precede the gateway block, which otherwise overrides the built-in mDNS allow.

AirPlay and AirDrop are excluded from cross-VLAN reflection. Their discovery within Default
is unaffected. Global IGMP snooping, L3 Network Isolation (ACL), Device Isolation (ACL) and
other switch defaults were left unchanged.

## Wired ports

For an endpoint on IoT, set its port's **Native VLAN / Network → IoT (20)** and
**Tagged VLAN Management → Block All**. Untagged endpoint traffic belongs to IoT; the device
does not need permission to send tagged traffic for other VLANs.

Check whether the endpoint uses DHCP before moving it. A manually configured static IP must
be changed as part of the move. Renew DHCP or reboot after changing the port.

Port isolation was not enabled. It is distinct from VLAN firewall rules and Wi-Fi client
isolation; check switch-specific behavior before applying it, especially across uplinks.

## Device connections and operating notes

Device addresses are fixed through DHCP reservations.

| Device                    | IoT address     | Integration / access                  |
|---------------------------|-----------------|---------------------------------------|
| Kindle                    | `192.168.20.10` | Internet for downloads and syncing    |
| Roborock Qrevo Edge 2 Pro | `192.168.20.20` | Roborock app; no HA integration       |
| SlimmeLezer / P1 reader   | `192.168.20.40` | HA DSMR over TCP 23; web UI on TCP 80 |
| Tado Internet Bridge      | `192.168.20.60` | HA HomeKit over TCP 80; no internet   |
| Nest Protect              | `192.168.20.30` | Nest app; internet exception          |
| Eufy                      | `192.168.20.50` | Internet allowed; no HA integration   |
| Tesla                     | Not recorded    | Internet allowed                      |

### Roborock

The Roborock has a device-specific allow for all internet protocols and ports.

To change Wi-Fi, hold Power/Clean + Dock/Home until “Resetting WiFi”, then use Add Device in
the Roborock app. This resets Wi-Fi, not factory settings.

Wi-Fi configuration requires the phone to be on the same IoT network with **Client Device
Isolation disabled**; this was verified. After pairing, the phone can return to its usual
network and client isolation can be re-enabled.

#### Abandoned attempt to restrict internet access

An attempt was made to configure specific internet exceptions instead of a broad allow-all
rule. Observed traffic included **63.183.234.65:443**, with an AWS load balancer hostname in
`eu-central-1`. No reliable Roborock-specific static IP/CIDR allowlist was found, so a TCP 443
exception was tried without restricting destination IPs.

Binding failed with **-3005.2**. Moving an initially misplaced TCP 443 allow above the internet
block fixed its ordering, but binding still failed. Expanding the exception to all protocols
and ports succeeded, and the attempt to narrow access was abandoned.

The additional required ports were not established. Older-model reports mention TCP 8883,
but that was not verified for this device. These observations are troubleshooting history,
not a complete list of networking requirements.

### Nest Protect

Change Wi-Fi in the **Nest app**, not Google Home:
Settings → Protect → Device options → Wi-Fi connection.

The Nest app connection check passed after migration; the device is working.

### SlimmeLezer

This reader is a Hi-Flying E20 serial-to-Ethernet bridge using HA's **DSMR integration over
TCP 23**, not ESPHome. See `p1-reader-corruption-2026-06.md` for hardware and stream details.
Its web interface is available to the authorized Macs at `http://192.168.20.40`.

When changing its address, update HA's DSMR connection too. The installed HA version had no
Reconfigure action, and the gear only exposed DSMR options. Stop HA, back up
`config/.storage/core.config_entries`, update the DSMR entry's host (port 23 unchanged), then
start HA. Do not edit storage while HA runs: the in-memory entry can overwrite the change.
The migration changed `192.168.1.130` to `192.168.20.40`.

### Tado

Use the existing **HomeKit Device** pairing. Moving the bridge between subnets does not
require deletion or re-pairing. The migration changed `192.168.1.104` to `192.168.20.60`.

Tado operates **fully locally through HomeKit**, which is working well. Internet access was
removed because the app was rarely used and the cloud integration required frequent manual
OAuth reauthorization (recalled as roughly weekly; the exact interval was not verified).
Local HomeKit does not require that cloud authentication.

If HA still retries the previous IP, check discovery from a Mac on Default:

```bash
# Browse HomeKit services.
dns-sd -B _hap._tcp local.
# Resolve the bridge's advertised hostname and TCP port.
dns-sd -L '<bridge instance name from browse output>' _hap._tcp local.
# Resolve the hostname's IPv4 address.
dns-sd -G v4 '<bridge hostname from lookup output>'
```

Replace the placeholders with the discovered values; Ctrl+C stops each command.
The expected result is **192.168.20.60:80**. Reload the existing HA integration after confirming
network access and discovery. Restarting HA or power-cycling the bridge can trigger a fresh
connection/announcement if needed; retain the pairing.

During migration, thermostat readings recovered gradually after HA learned the new address.
HA temporarily logged `KeyError: None` for HVAC mode and
`None is not a valid TemperatureDisplayUnits`; some cards showed invalid **100 °C** readings
and a 5 °C setpoint. App control still worked, and all HomeKit readings eventually recovered.
All thermostats use the same bridge connection; separate firewall rules per thermostat are
unnecessary. A cloud-integration authentication error is separate from HomeKit pairing.

## Adding or moving devices

1. Check its local integrations and internet needs. Add the necessary device-specific rules
   before moving it; do not grant general IoT → Internal access.
2. Connect it to the IoT SSID or assign its wired endpoint port to IoT.
3. Reserve its IP if needed and update any integration's host address.
4. Check discovery, control, readings, and app functions. Restore any temporarily disabled
   isolation settings.
5. Remove obsolete rules for its previous network once verified.
6. Update this document's policy, device and port tables with the applied configuration.

For a new custom zone, this UI may require creating the network under Internal first, then
creating the zone and assigning the network. Do this before connecting devices.

## Troubleshooting and verification

Inspect **UniFi firewall events in the UI**, filtering by device/IP. Events appear without
requiring the policy's **Syslog Logging** option; that option forwards to a remote logging
server. Details show the matching rule, direction, destination, and protocol/port. Raw CEF
may help, but the observed ICMP event did not include type/code.

For connectivity checks, use a temporary client on IoT without an internet exception:

- Confirm it receives `192.168.20.x` and resolves DNS through the gateway.
- Confirm NTP works (`sntp pool.ntp.org`).
- Confirm general internet is blocked (`curl --connect-timeout 5 https://example.com`).
- Confirm Internal services such as `192.168.1.138:22`, `:1883` and `:8123` are blocked.
- Confirm gateway administration is blocked while the documented exceptions work.
- From an authorized Mac on Default, test IoT web access; test that other clients/ports remain
  blocked and Wi-Fi clients cannot communicate directly when isolation is enabled.

When changing policies, check the directed zone pair's rule order before broadening access.
Observe normal operation and less frequent functions such as updates before narrowing ports.

## Maintenance and details to confirm

The obsolete Default-network internet block for SlimmeLezer has been removed.

- [ ] Observe device traffic during normal use and updates before deciding whether narrower
      internet exceptions are worthwhile.

## Work not yet configured

- Ulanzi TC002: connect with current/out-of-the-box firmware and test connectivity later.
  Firmware flashing and HA integration are separate work.
- Duux fans: no VLAN move, broker migration or DNS changes made here.
- IoT MQTT broker/bridge: separate work. Unencrypted MQTT is acceptable for that future setup;
  TLS/certificate management is not planned.
- Per-device Wi-Fi passwords (PPSK) and wired port isolation can be considered separately.

## Reverting a migration

Move the device back to its previous Wi-Fi or restore its port's native Default VLAN, renew
DHCP, and restore any changed HA host setting. Keep HomeKit pairing. Update this reference
and remove obsolete exceptions after verifying the reverted connection.
