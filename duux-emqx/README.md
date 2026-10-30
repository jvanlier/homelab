# duux-emqx

Dedicated EMQX broker for the two **Duux Whisper Flex 2** fans. Kept isolated from the internal `mqtt/` mosquitto broker by design — the fans are LAN Wi-Fi clients, so this broker is LAN-exposed (port 443), while the internal bus is loopback-only.

The `duux_fan_local` Home Assistant custom integration is baked into the HA image (see `home-assistant-amb/docker/Dockerfile`). It connects with its own paho-mqtt client (always TLS, cert not verified) directly to this broker — it does **not** use HA's core MQTT integration.

## How the hijack works

1. The fans talk to `collector3.cloudgarden.nl:443` over MQTT-TLS.
2. A UniFi DNS rewrite points that hostname at the Pi's LAN IP.
3. EMQX listens on `0.0.0.0:8883`, published on the Pi LAN address `192.168.1.138:443`.
4. The fans connect to EMQX instead of the cloud.

## Secrets (not in git)

| File                                  | Contents                                         |
|---------------------------------------|--------------------------------------------------|
| `certs/collector3.cloudgarden.nl.key` | TLS private key                                  |
| `certs/collector3.cloudgarden.nl.crt` | Self-signed TLS cert                             |
| `auth-bootstrap.json`                 | Real credentials (copy from `.example`, fill in) |

## One-time setup

### 1. Generate the self-signed certificate

Run from the `duux-emqx/` directory on the Pi:

```bash
mkdir -p certs
openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout certs/collector3.cloudgarden.nl.key \
  -out    certs/collector3.cloudgarden.nl.crt \
  -days 3650 \
  -subj "/CN=collector3.cloudgarden.nl" \
  -addext "subjectAltName=DNS:collector3.cloudgarden.nl"
```

The cert CN/SAN must match `collector3.cloudgarden.nl` — the fan firmware verifies the hostname (or at minimum paho does on the HA side; either way it costs nothing to match).

### 2. Capture fan credentials (socat MITM)

The fans use their **MAC address** (lowercase, colon-separated, e.g. `aa:bb:cc:dd:ee:ff`) as the MQTT username, and a 64-character password. To get them, intercept the first TLS connection.

Do this **per fan**, **before** bringing EMQX up:

```bash
apt-get install -y socat

# Run on the Pi (as root, since :443 is privileged):
socat OPENSSL-LISTEN:443,reuseaddr,fork,cert=certs/collector3.cloudgarden.nl.crt,key=certs/collector3.cloudgarden.nl.key,verify=0 STDOUT 2>&1 | tee duux_capture_fan1.log
```

Then:
1. Set the UniFi DNS rewrite: `collector3.cloudgarden.nl → <PI_LAN_IP>` (see below).
2. Reboot the fan: unplug → remove battery if applicable → wait ~1 s → reinsert → power on.
3. Watch the log. The CONNECT packet contains the username and password in plain text.
4. Stop socat (`Ctrl-C`).
5. Repeat for the second fan (rename the log file).

Example capture output (excerpt):
```
...CONNECT...aa:bb:cc:dd:ee:ff...64characterpasswordhere...
```
The topic prefix in the published messages (`sensor/<mac>/...`) confirms the username/device id.

### 3. Fill in credentials

```bash
cp auth-bootstrap.json.example auth-bootstrap.json
# Edit auth-bootstrap.json: set ha password, and one entry per fan MAC
# Edit acl.conf: replace the <MAC> placeholders with the real fan MAC(s)
```

`auth-bootstrap.json` uses EMQX's bootstrap format — the key is **`user_id`** (not `username`),
and `bootstrap_type = plain` (set in `emqx.conf`) means passwords are stored as written.

Also choose a strong password for `ha` — this is what you'll enter in the HA integration config flow.

> **Important:** the bootstrap file is only read on the **first** start of a fresh data
> volume. If EMQX already ran once, the built-in DB is non-empty and the file is ignored.
> To re-bootstrap: `docker compose down -v && docker compose up -d` (the `-v` wipes the
> EMQX data volume). Alternatively add users live via the dashboard
> (**Access Control → Authentication → Built-in Database → User Management → + Add**).

### 4. UniFi DNS rewrite

Console → Settings → Policy Engine → DNS → Create a new **Host (A)** entry:

| Hostname                    | IP            |
|-----------------------------|---------------|
| `collector3.cloudgarden.nl` | `<PI_LAN_IP>` |

### 5. Deploy EMQX

```bash
cd duux-emqx
docker compose up -d
```

Verify the TLS listener bound:
```bash
docker logs duux-emqx | grep "SSL listener"
```

Dashboard (read-only check, via SSH tunnel from your laptop):
```bash
ssh -L 18083:127.0.0.1:18083 pi@<PI_LAN_IP>
# then open http://localhost:18083 (default creds: admin / public, change on first login)
```

### 6. Reboot both fans

Unplug each fan, wait ~1 s, power back on. After ~30 s they should appear as connected clients in the EMQX dashboard under "Clients".

### 7. Deploy + rebuild Home Assistant

The `duux_fan_local` component is baked into the image:

```bash
cd home-assistant-amb
docker compose up -d --build
```

### 8. Add the integration (×2, once per fan)

In HA: **Settings → Devices & Services → Add Integration → "Duux Fan Local"**

| Field     | Value                                                                      |
|-----------|----------------------------------------------------------------------------|
| MQTT Host | `collector3.cloudgarden.nl`                                                |
| MQTT Port | `443`                                                                      |
| Username  | `ha`                                                                       |
| Password  | `<ha password from auth-bootstrap.json>`                                   |
| Model     | Whisper Flex 2                                                             |
| Name      | e.g. `Bedroom JC` / `Study`                                                |
| Device ID | Fan's MAC address, lowercase **colon-separated**, e.g. `aa:bb:cc:dd:ee:ff` |

The Device ID must match the MAC in the fan's MQTT topic (`sensor/<mac>/in`) exactly —
colons included. Using a colonless form subscribes to the wrong topic and the entity
never updates.

Repeat for the second fan with its own name and MAC.

## Verification

- Both fans appear as connected EMQX clients in the dashboard.
- Each fan creates a device in HA with fan + sensor entities.
- Toggling power / speed in HA actuates the physical fan.
- Manual state changes on the fan (e.g. via its remote) reflect back in HA within a few seconds.

## Port summary

| Port    | Binding             | Purpose                        |
|---------|---------------------|--------------------------------|
| `443`   | `192.168.1.138:443` | MQTT-TLS — fans connect here   |
| `18083` | `127.0.0.1:18083`   | EMQX dashboard (loopback-only) |
