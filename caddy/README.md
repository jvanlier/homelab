# Caddy

Caddy runs on pi502 and routes the four DNS names to services on the same Pi. It listens on port 80 of the Tailscale IP `100.88.31.116`; traffic between devices is encrypted by Tailscale. Use `http://` in the browser.

| DNS name              | Service           |
|-----------------------|-------------------|
| `hass.<domain>`       | Home Assistant    |
| `tm.<domain>`         | TeslaMate         |
| `tm-grafana.<domain>` | TeslaMate Grafana |
| `z2m.<domain>`        | Zigbee2MQTT       |

## Setup on pi502

1. Point the four DNS A records to `100.88.31.116`.
2. Copy `.env.example` to `.env` and set `DOMAIN` to the common DNS suffix (for example, `example.com`).
3. Deploy the Home Assistant configuration in this repository and restart Home Assistant so it trusts the local proxy.
4. Run `docker compose up -d` in this directory.
5. From a device connected to the tailnet, open `http://hass.<domain>`, `http://tm.<domain>`, `http://tm-grafana.<domain>`, and `http://z2m.<domain>`.
6. In TeslaMate, set **Settings → URLs** to `http://tm.<domain>` for the web app and `http://tm-grafana.<domain>` for dashboards.

The Duux MQTT broker continues to use port 443.

## TransIP credentials for HTTPS

To prepare for DNS-based certificate issuance, set `TRANSIP_LOGIN` in `.env` and save the private key generated in the TransIP control panel as `transip-private-key.pem`. The `.pem.example` file shows the expected format. Both files are ignored by git; keep the private key readable only by its owner (`chmod 600 transip-private-key.pem`).

These credentials are not used by the current HTTP configuration; the TransIP plugin and HTTPS still need to be configured.
