# Samba and Time Machine on pi501

Samba runs in Docker with a read-only media share and two Time Machine shares:

| Share                 | Host directory             | Samba limit | Hard quota |
|-----------------------|----------------------------|------------:|-----------:|
| `pi-share`            | `/srv/media`               |           — |          — |
| `TimeMachine-Jori`    | `/srv/timemachine/jori`    |     480 GiB |    500 GiB |
| `TimeMachine-Chantal` | `/srv/timemachine/chantal` |     240 GiB |    250 GiB |

The hard quotas are enforced by the host filesystem. Samba's limits are slightly lower because its size calculation is approximate. These quotas cover all files owned by each backup account on the root filesystem.

## Setup

Use a Raspberry Pi running Debian Bookworm or Trixie with an ext4 root filesystem, internet access and **at least 800 GiB free on `/`**. The default limits total 750 GiB, leaving at least 50 GiB for the system. The Pi had about 812 GiB free when these limits were chosen; backup history will be limited.

Run from a terminal on the Pi, in this repository's `samba` directory. Stop other workloads that write to `/` first: preparation initializes quota accounting on the live filesystem.

```bash
cd /path/to/homelab/samba
sudo ./setup.sh prepare
sudo reboot
```

After the Pi reboots:

```bash
cd /path/to/homelab/samba
sudo ./setup.sh install
```

Preparation installs the host dependencies and, if necessary, Docker and its Compose and Buildx plugins. It creates the accounts and directories, backs up `/etc/fstab`, and configures user quotas. Installation verifies quotas survived the reboot and actually block excess writes, builds the image, installs discovery and startup configuration, and prompts for three Samba passwords. For `media`, reuse the current password if existing clients should keep their saved credentials.

Trixie may print a deprecation notice for external quota files; installation checks that quota enforcement works after reboot. The scripts refuse to replace existing quota configurations, backup accounts or unrelated host service files.

### Existing media

On a fresh Pi the script creates an empty `/srv/media`. On an existing Pi, place your media files there yourself before setup, preserving their ownership and permissions. The `media` account must be able to read them. The setup never moves or modifies `/media`.

If replacing a host Samba server, stop it before running the install phase so port 445 is free. Keep the old configuration and account database until the container has been verified.

## Connect and verify

Check the media share with its Samba password:

```bash
smbclient //localhost/pi-share -U media -c 'ls'
```

On each Mac, choose its corresponding share in **System Settings → General → Time Machine**, sign in with its Samba account and enable backup encryption. If it does not appear, first connect in Finder to `smb://pi501.local/TimeMachine-Jori` or `smb://pi501.local/TimeMachine-Chantal`.

After the first backups, restore a file from each Mac. Check quotas and free space on the Pi:

```bash
sudo /usr/local/sbin/samba-quota-check
sudo quota -v -u tm-jori
sudo quota -v -u tm-chantal
df -h /
```

Keep another backup of irreplaceable data on a separate device or off-site.

## Operation

Use systemd to start, stop or restart Samba; its startup check prevents the container from starting without the correct host quotas. If that check fails, the media share is also unavailable. Do not start the service with `docker compose up` directly.

```bash
sudo systemctl status samba-container
sudo journalctl -u samba-container
sudo systemctl restart samba-container
```

After changing `smb.conf` or the Dockerfile, rebuild and restart from `samba/`:

```bash
sudo docker compose build
sudo systemctl restart samba-container
```

Keep Docker's `samba-state` volume: it holds the Samba account database. If the checkout moves, update `/etc/default/samba-container` with the new absolute directory before restarting. Changing the quota limits also requires updating `smb.conf`, `quota-check.sh` and the host quotas.

## Recovery and rollback

If preparation stops before completion, inspect the error and `/var/lib/homelab-samba-setup`. To undo partial quota setup, compare `/etc/fstab` with `/etc/fstab.before-timemachine` if it exists, restore the original root options and reboot. Once quotas are off, remove only the empty backup directories and accounts created by this setup, and archive `/aquota.user`, the fstab backup and setup state before retrying. Preserve any backup data.

If installation is interrupted during the quota write test, remove its `quota-test` file from the affected empty backup directory, restore that account's hard quota with `sudo setquota -u tm-jori 0 500G 0 0 /` or `sudo setquota -u tm-chantal 0 250G 0 0 /`, and retry installation.

To return to a host Samba server, stop the container and its advertisement:

```bash
sudo systemctl disable --now samba-container
sudo rm /etc/avahi/services/samba-timemachine.service
sudo systemctl restart avahi-daemon
```

Restore your host Samba service and media files. Keep the backup directories and Docker's account volume until you have verified the replacement.
