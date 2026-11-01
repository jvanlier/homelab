# Operate Samba

## Check the service

Use systemd to manage Samba. The startup check prevents the container from starting without the required host quotas; if it fails, the media share is also unavailable. Do not start the service with `docker compose up` directly.

```bash
sudo systemctl status samba-container
sudo journalctl -u samba-container
sudo systemctl restart samba-container
```

## Check quotas and free space

```bash
sudo /usr/local/sbin/samba-quota-check
sudo quota -v -u tm-jori
sudo quota -v -u tm-chantal
df -h /
```

See the [configured limits](reference.md#shares) and [how they work](architecture.md#storage-and-quotas).

## Rebuild after a configuration change

After changing `smb.conf` or the Dockerfile, rebuild and restart from the `samba/` directory:

```bash
sudo docker compose build
sudo systemctl restart samba-container
```

Quota limits also appear in `setup.sh` and `quota-check.sh` and are enforced by the host. The startup guard is installed separately at `/usr/local/sbin/samba-quota-check`; rebuilding the image does not update it or the host quotas.

## Move the checkout

Update `SAMBA_DIR` in `/etc/default/samba-container` to the new absolute `samba` directory, then restart `samba-container`.

## Recover an interrupted setup

If preparation stops before completion, inspect the error and `/var/lib/homelab-samba-setup`. To undo partial quota setup, compare `/etc/fstab` with `/etc/fstab.before-timemachine` if it exists, restore the original root options and reboot. Once quotas are off, remove only the empty backup directories and accounts created by this setup, and archive `/aquota.user`, the fstab backup and setup state before retrying. Preserve any backup data.

If installation is interrupted during the quota write test, remove its `quota-test` file from the affected empty backup directory, restore that account's hard quota with `sudo setquota -u tm-jori 0 500G 0 0 /` or `sudo setquota -u tm-chantal 0 250G 0 0 /`, and retry installation.

## Return to a host Samba server

Stop the container and its advertisement:

```bash
sudo systemctl disable --now samba-container
sudo rm /etc/avahi/services/samba-timemachine.service
sudo systemctl restart avahi-daemon
```

Restore your host Samba service and media files. Keep the backup directories and Docker's account volume until you have verified the replacement.
