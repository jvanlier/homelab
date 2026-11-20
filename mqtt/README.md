# mqtt

Single shared MQTT broker for the trusted internal services: zigbee2mqtt, teslamate,
Home Assistant, and frigate (future). All of these are co-located on the Pi and
communicate over a shared Docker bridge network or the host loopback — not the LAN.

A second, separate listener accepts a few Wi-Fi devices (AWTRIX clocks on the IoT VLAN)
over TLS with a login and per-device ACL. See [LAN listener](#lan-listener-tls-8883).

## Why a dedicated directory instead of living inside zigbee2mqtt-amb or teslamate

No single service owns the broker — it is shared infrastructure used by at least four
services. Embedding it inside one service's compose file creates a false ownership
dependency and causes the broker to be stopped/started as a side effect of that
service's lifecycle. A dedicated `mqtt/` directory with its own compose project
makes the dependency explicit and the lifecycle independent.

## Security posture (loopback-bind, keep anonymous)

This section covers the internal listener (1883). The internal port is bound to `127.0.0.1` only. This is deliberate and sufficient:

- **zigbee2mqtt** and **teslamate** reach the broker container-to-container over the
  shared `mqtt` Docker bridge network — they never touch the published port.
- **Home Assistant** and **frigate** run with `network_mode: host` and reach the
  broker via `localhost:1883` — the host loopback, not the LAN interface.

Binding to `127.0.0.1` fully closes the threat surface (LAN guests, IoT devices,
accidental internet exposure) with zero credential overhead. It is strictly better
than the previous setup where the zigbee2mqtt broker was bound to `0.0.0.0:1884`.

Password authentication was deliberately **not** used. MQTT passwords are transmitted
as plaintext without TLS, so they add nothing against a network attacker. Nothing
untrusted can reach a loopback-only listener in the first place, so auth/ACL would
only guard against an in-host/compromised-container threat — out of scope here.

## Networking

A shared external Docker network named `mqtt` connects the broker to its clients:

```
docker network create mqtt
```

This command must be run once on the Pi before bringing up any of the compose projects.
Clients resolve the broker by the service alias `mqtt` on port 1883 (standard port;
this ends the old `1884` workaround that existed because teslamate occupied 1883 first).

## No MQTT-over-WebSockets (port 9001)

Only the TCP listener on 1883 is exposed. The old z2m compose published `9001:9001`
(the conventional MQTT-over-WebSockets port) but never declared a matching
`listener 9001` / `protocol websockets` in its config — so nothing ever bound 9001 and
the mapping was dead. It was dropped here rather than carried over.

None of the current clients (zigbee2mqtt, teslamate, Home Assistant, frigate) need
WebSockets — that transport only matters for browser-side / JavaScript MQTT clients. To
add it later, declare another listener in `mosquitto.conf`:

```
listener 9001
protocol websockets
allow_anonymous true
```

and re-add `- "127.0.0.1:9001:9001"` to the compose `ports`.

## LAN listener (TLS, 8883)

Wi-Fi devices can't use the loopback listener, so `mosquitto.conf` adds a second
listener with `per_listener_settings true`. That keeps the auth settings separate:

| Listener | Published on          | Auth                        | Clients                     |
|----------|-----------------------|-----------------------------|-----------------------------|
| 1883     | `127.0.0.1`           | anonymous, full access      | HA, z2m, teslamate, frigate |
| 8883     | `192.168.1.138` (LAN) | TLS + password + `acl.conf` | AWTRIX clocks               |

- **TLS** keeps the password and messages unreadable on the network. The certificate is
  self-signed and valid for 10 years. Clients trust it by pinning its SHA-256 fingerprint
  (AWTRIX NG's **Trust** button), so there is no CA and no renewal.
- **ACL**: a LAN user can only use `<username>/#` and publish its own HA discovery config
  (`homeassistant/device/<client id>/config`). It cannot see or send zigbee, tesla or other
  internal topics. Give each device's MQTT prefix the same value as its username.
- **Firewall**: UniFi only allows specific IoT devices to reach `192.168.1.138:8883`
  (see `docs/unifi-ucg-ultra.md`).
- **Secrets** live in `mqtt/lan/` on the Pi (gitignored): `server.crt`, `server.key`, `passwd`.
  The container entrypoint chowns them to the `mosquitto` user, so later edits on the host
  need `sudo` or the `just` recipes.

HA needs no changes: it stays on the internal listener and sees the device topics because
both listeners share one broker.

### Setup (once, on pi502 in `mqtt/`)

Mosquitto refuses to start while the cert or password file is missing, so create them
before restarting:

```
just tls-cert
just add-user awtrix_kids_bedroom   # prompts for a password
docker compose up -d                # recreates the container with port 8883
just fingerprint                    # compare with the clock before pressing Trust
```

Add more devices with `just add-user <name>`. It reloads the broker, so no restart is needed.

## No cross-project `depends_on`

The broker lives in its own compose project. Docker Compose `depends_on` only works
within a single project, so zigbee2mqtt and teslamate cannot declare a hard startup
dependency on this broker. This is fine: both services reconnect automatically on
failure and carry `restart` policies. Bring `mqtt/` up first (see Deployment)
to avoid harmless startup error spam in the client logs.

## Port choice: 1883

Port 1883 is the MQTT standard. The old workaround (z2m on 1884 because teslamate
claimed 1883) is gone. Frigate's default MQTT config also assumes `localhost:1883`, so
enabling frigate's MQTT integration in the future will require no port change.

## Deployment

1. **Create the shared network once** (on the Pi):
   ```
   docker network create mqtt
   ```

2. **(Optional) Preserve retained messages** from the old z2m broker:
   ```
   cp -a zigbee2mqtt-amb/mosquitto-data mqtt/mosquitto-data
   ```
   If skipped, the broker starts fresh. zigbee2mqtt re-publishes HA discovery messages
   on connect, so devices repopulate automatically — acceptable either way.

3. **Bring up the broker first:**
   ```
   cd mqtt && docker compose up -d
   ```

4. **Bring up zigbee2mqtt-amb** (broker service removed; z2m now joins the shared net):
   ```
   cd zigbee2mqtt-amb && docker compose up -d
   ```
   Verify the z2m frontend (`:8002`) shows "Connected".

5. **Reconfigure the HA MQTT integration** in the UI: change the broker port from
   `1884` to `1883` (host stays `localhost` / `127.0.0.1`). Reload the integration.

6. **Bring up teslamate** (old broker removed; teslamate now joins the shared net):
   ```
   cd teslamate && docker compose up -d
   ```

## Future: Duux fans (separate dedicated broker)

The two Duux fans (duux-fan-local) need their **own separate broker** and must NOT
share this one. The fans are LAN Wi-Fi clients, so their broker must expose a
LAN-routable TLS listener (spoofing the cloud host via Pi-hole DNS rewrite and a
self-signed certificate). That listener's fragile cloud-spoofing plumbing (below) is why
the fans stay on their own broker, even though this broker now has a restricted LAN
listener for AWTRIX.

Keeping the brokers separate also limits blast radius: a LAN-exposed broker is the
most-probed surface on the network, and the internal zigbee/tesla topics must remain
unreachable from it. The Duux side also carries its own fragile plumbing (TLS cert
renewal, DNS rewrite, `443→8883` nftables redirect) that must not risk the z2m /
teslamate / HA bus.

If HA needs fan sensor data, bridge only the relevant fan topic one-way (Duux broker →
this broker) via a Mosquitto `connection` directive. HA keeps its single integration
pointed at this internal broker and never needs to know about the Duux broker directly.
