# Denon AVR-X3000 networking findings

The AVR-X3000 is on IoT VLAN 20 at DHCP reservation **192.168.20.70**, wired through
a USW Flex Mini. Its endpoint port uses native IoT and blocks tagged VLANs; uplinks
must carry VLAN 20. The applied policies are maintained in the
[network reference](unifi-ucg-ultra.md).

## Verified result

- AirPlay works from an iPhone on Default with mDNS restricted to the HomeKit,
  AirPlay and Spotify Connect presets.
- AirPlay required a separate Denon → Default UDP allow. Automatic return traffic
  on the trusted → Denon rule alone was insufficient: the receiver appeared in the
  output picker, but connection attempts timed out. Restricting the reverse allow
  to UDP still allowed reconnection, playback and track changes.
- Spotify Connect works from Mac and iPhone with the restricted internet rule,
  including after a receiver power cycle, app restart, fresh connection, track
  skipping and album changes.
- Quitting Spotify on the Mac did not interrupt playback or iPhone control.
  The Denon streams directly from Spotify; the Mac does not relay the audio.

UniFi's device fingerprint labeled it AVR-X2300W, but its advertised model and
Spotify API identify it as AVR-X3000.

## AirPlay and discovery

Observed services:

| Service                 | Advertised endpoint           | Notes                                        |
|-------------------------|-------------------------------|----------------------------------------------|
| `_raop._tcp`            | `Denon-AVR-X3000.local.:1025` | TXT record advertises `tp=UDP`               |
| `_spotify-connect._tcp` | `Denon-AVR-X3000.local.:80`   | TXT record has `CPath=/goform/spotifyConfig` |

The advertised hostname resolved to `192.168.20.70`. AirPlay TCP port 1025 and
Spotify's HTTP endpoint were reachable from the Mac.

Discovery requires both Denon → Gateway exceptions above `IoT block gateway`:

- Multicast: destination `224.0.0.251`, UDP destination port 5353.
- Unicast replies: destination `192.168.20.1`, UDP **source** port 5353,
  destination port Any. Blocked replies used temporary destination ports 43989
  and 34180; allowing only multicast did not cover them.

The unicast rule subsequently received hits. Its individual effect on Spotify
visibility was not isolated. Broad mDNS service reflection was temporary;
AirPlay was retested successfully after restoring the three specific presets.

`Denon allow AirPlay UDP to trusted` permits UDP to Default on any port, with
Auto Allow Return Traffic enabled. Its generated return rule appears in
Internal → IoT and matches return traffic only. Trusted → Denon remains an
allow for all protocols/ports scoped to the receiver's IP. Specific negotiated
AirPlay UDP ports were not captured.

## Spotify internet exception

`Denon allow Spotify`, above `IoT block internet`:

- Source: Denon device in IoT.
- Destination: External, Domain → Specific:
  - `spotify.com`
  - `ap.single-gslb.spotify.com`
  - `audio-ak-spotify-com.akamaized.net`
- IPv4, TCP destination ports **80, 443, 4070**, source port Any.
- Auto Allow Return Traffic off; External already handles replies.
- Shared all-IoT UDP 123 internet allowance remains for NTP.

A blocked event identified `ap.single-gslb.spotify.com` at `34.158.1.133:80`.
It was added explicitly. This does **not** establish whether UniFi's base-domain
entry includes subdomains, or whether the original domain list was insufficient:
rule timing, ordering and client behavior were not isolated.

A temporary Denon-only unrestricted internet rule was used during diagnosis and
then restored to the restriction above. A brief loss of control immediately after
saving did not persist. The final restricted configuration passed the tests in
"Verified result".

Spotify's [live resolver](https://apresolve.spotify.com/?type=accesspoint&type=dealer&type=spclient)
returned regional access points using TCP 4070/443/80 and dealer/spclient services
using TCP 443. These are dynamic endpoints, not a fixed IP allowlist.
[Spotify staff state that a complete domain allowlist is not public](https://community.spotify.com/forum/en/discussion/5481736/domains-to-whitelist-for-spotify).
The applied list is verified for this setup, not guaranteed exhaustive.

### Remaining blocked CDN request

A later event blocked `2.21.23.86:80`. Reverse DNS returned an Akamai hostname.
Spotify audio delivery is plausible, but no DNS query or HTTP Host header was
captured to identify the request. Playback worked, so it was left blocked.
Do not treat the IP as a confirmed Spotify endpoint. Its Netherlands geolocation
still represents external internet traffic.

## iPhone visibility and Limit IP Address Tracking

On the iPhone's trusted Wi-Fi connection, **Limit IP Address Tracking** reproducibly
controlled HTTP reachability to `192.168.20.70`: enabled caused timeouts in both
Safari and Firefox; disabled restored access. Toggle it under
**Settings → Wi-Fi → ⓘ → Limit IP Address Tracking**. HTTP worked from the Mac,
and the trusted → Denon rule already allowed all clients, protocols and ports.
The setting's effect was confirmed by toggling it both ways; the underlying
Private Relay/routing mechanism was not captured.

The receiver later appeared in the iPhone Spotify picker after a Mac initiated
Spotify Connect playback. The phone could control it after quitting Spotify on
the Mac and could reconnect after restarting its own app. Spotify cloud control
explains operation without proving local HTTP access or local discovery on the
phone worked at that point. HTTP access was subsequently restored by disabling
Limit IP Address Tracking; its effect on fresh Spotify discovery was not separately
tested. Initial setup by another trusted device/account was not tested.

[Spotify's developer FAQ](https://developer.spotify.com/documentation/commercial-hardware/implementation/faqs)
describes local discovery: browse mDNS, read the service port and CPath, then
request `getInfo` over HTTP. A receiver already logged into the same account can
also appear despite local discovery errors.

## Useful diagnostics

From a Mac on Default (Ctrl+C stops discovery commands):

```bash
dns-sd -B _raop._tcp local.
dns-sd -B _spotify-connect._tcp local.
# Use the instance returned by the Spotify browse command.
dns-sd -L '<instance>' _spotify-connect._tcp local.
dns-sd -G v4 Denon-AVR-X3000.local.
curl --connect-timeout 3 'http://192.168.20.70/goform/spotifyConfig?action=getInfo'
route -n get 192.168.20.70
```

The observed `getInfo` response reported `remoteName: Denon AVR-X3000`,
`spotifyError: 0`, and `accountReq: PREMIUM`. Avoid publishing the full response:
it also contains account and device identifiers.

Initial Mac ping/HTTP tests were misleading because a VPN routed the IoT subnet
through a tunnel. Binding HTTP to the local Wi-Fi address succeeded, and the VPN
was subsequently disabled. Check routing before changing firewall rules.

In UniFi, inspect the relevant directed zone pair and put exceptions above its
block. Filter firewall events by the receiver's IP; distinguish multicast mDNS,
unicast replies to the gateway, and actual external connections. Hit counters
show a rule matches traffic, not that an entire service works.
