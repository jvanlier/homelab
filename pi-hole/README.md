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

## Network DNS

The UniFi DHCP server is configured to advertise Pi-hole as the DNS server to
clients. Clients receive this setting when they obtain or renew their DHCP lease.
Pi-hole forwards queries that are not blocked locally to the Quad9 upstreams above.

## Security adlists

`adlists.txt` tracks HaGeZi Multi PRO and Threat Intelligence Feeds Medium.
Apply them on the Pi running this Compose service (requires Python 3 and Docker
Compose):

```bash
python3 apply_adlists.py
```

The script prompts for your Pi-hole password and uses the local Pi-hole v6 API
on port 8001. If you use two-factor authentication, enter a Pi-hole application
password with list-editing permission instead. Passwords are not saved.

It adds missing blocklists to the default group, closes its API session, and runs
`pihole -g` inside the container. Existing lists, including disabled lists and
their group assignments, are left unchanged. Removing a URL from `adlists.txt`
does not remove it from Pi-hole; remove unwanted lists through the web interface.
If applying fails partway through, fix the error and rerun: already added lists
will be skipped.

Run the script after adding URLs in Git. Pi-hole's scheduled Gravity updates
refresh the feeds afterward.
