pi-hole
======

Setup:

```
mkdir -p var-log
touch var-log/pihole.log
```

Create `.env` file with WEBPASSWORD.

Webinterface will run on port 8001 (http) because 80 is already taken by Traefik in TeslaMate.

Upstream DNS uses Quad9's security-filtering resolvers (`9.9.9.9` and
`149.112.112.112`), configured through `FTLCONF_dns_upstreams` in
`docker-compose.yml`. This setting is read-only in the Pi-hole web interface.
To change it, edit the Compose file and recreate the container:

```bash
docker compose up -d
```
