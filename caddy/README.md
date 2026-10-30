# Caddy

Caddy runs on pi502 and routes the four DNS names to services on the same Pi. It listens on ports 80 and 443 of the Tailscale IP `100.88.31.116`. Caddy obtains and renews trusted certificates using the TransIP DNS API.

| DNS name              | Service           |
|-----------------------|-------------------|
| `hass.<domain>`       | Home Assistant    |
| `tm.<domain>`         | TeslaMate         |
| `tm-grafana.<domain>` | TeslaMate Grafana |
| `z2m.<domain>`        | Zigbee2MQTT       |

## Setup on pi502

1. Point the four DNS A records to `100.88.31.116`.
2. Enable API access in TransIP and generate a key pair that can update DNS. Copy `.env.example` to `.env` and set `DOMAIN` to the common DNS suffix and `TRANSIP_LOGIN` to your TransIP account name. Save the generated private key as `transip-private-key.pem` (see `.pem.example`), and run `chmod 600 transip-private-key.pem`. Both files are ignored by git.
3. Deploy the Home Assistant configuration in this repository and restart Home Assistant so it trusts the local proxy.
4. In `duux-emqx/`, run `docker compose up -d` to move the broker to the Pi LAN address `192.168.1.138:443`. This briefly interrupts fan connections.
5. In `caddy/`, run `docker compose up -d --build`. Check `docker compose logs -f` for certificate issuance.
6. From a device connected to the tailnet, open `https://hass.<domain>`, `https://tm.<domain>`, `https://tm-grafana.<domain>`, and `https://z2m.<domain>`. HTTP requests redirect to HTTPS.
7. In TeslaMate, set **Settings → URLs** to `https://tm.<domain>` for the web app and `https://tm-grafana.<domain>` for dashboards.

Caddy uses the DNS challenge, so the Pi does not need to be reachable from the public internet. The DNS API key must remain available for certificate renewal.
