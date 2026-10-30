# Samba and Time Machine on pi501

This setup moves pi501's existing Samba service into Docker. It keeps the `pi-share` media share at `/media`, read-only and accessible to `media`, and adds separate Time Machine shares:

| Mac     | Share                 | Samba-reported limit | Hard user quota |
|---------|-----------------------|---------------------:|----------------:|
| Jori    | `TimeMachine-Jori`    |              480 GiB |         500 GiB |
| Chantal | `TimeMachine-Chantal` |              240 GiB |         250 GiB |

The backup directories live on pi501's ext4 root filesystem. Samba's reported limit is approximate; host filesystem quotas enforce the hard limits. Each quota applies to **all files owned by that account on the root filesystem**, so keep the backup accounts dedicated to Time Machine.

The Pi had about 812 GiB free when this was planned. If both quotas fill, roughly 62 GiB remains for the system and other files. These limits leave little room for backup history, so monitor free space and consider a larger disk if needed.

## 1. Prepare pi501

These instructions assume a Debian-based Pi with rootful Docker and Docker Compose installed. Run commands on pi501, from this repository's `samba` directory:

```bash
cd /path/to/homelab/samba
findmnt -no SOURCE,FSTYPE,OPTIONS /
df -h /
sudo docker compose version
sudo docker info --format '{{json .SecurityOptions}}'
sudo apt-get update
sudo apt-get install avahi-daemon quota smbclient
```

Confirm `/` is the expected ext4 filesystem, has enough free space, and Docker's security options do not include `rootless`. The container uses the host's numeric user IDs; rootless Docker remaps them and would prevent the intended quota accounting.

Check the existing media account and share before migrating:

```bash
getent passwd media
getent passwd nobody
sudo testparm -s
sudo -u media test -r /media && sudo -u media test -x /media
```

Confirm that the current `pi-share` uses `/media`, is read-only and allows `media`, as described in the original setup. If the live setup differs, adjust `smb.conf` and `docker-compose.yml` to match before switching. The existing host Samba configuration, passwords and media files are not modified by the container setup.

These steps assume user quotas are not already configured on `/`. Check for an existing configuration:

```bash
sudo quotaon -u -p /
sudo tune2fs -l "$(findmnt -no SOURCE /)" | grep 'Filesystem features'
findmnt --fstab -no OPTIONS /
sudo find / -maxdepth 1 \( -name aquota.user -o -name quota.user \) -ls
```

If user quotas are already on, the filesystem features include `quota`, the root fstab options already configure quotas, or either quota file exists, stop and inspect the existing setup. Do not replace an existing quota configuration with these instructions.

## 2. Enable and verify host quotas

Back up `/etc/fstab`, then edit it:

```bash
sudo cp /etc/fstab /etc/fstab.before-timemachine
sudo nano /etc/fstab
```

On the **existing line whose mount point is `/`**, append `usrjquota=aquota.user,jqfmt=vfsv0` to its comma-separated mount options. Keep its existing device identifier, options and other fields. For example, if the options were `defaults,noatime`, they become:

```text
defaults,noatime,usrjquota=aquota.user,jqfmt=vfsv0
```

Do not add a second root filesystem line. Validate and remount:

```bash
sudo findmnt --verify --verbose
sudo mount -o remount /
findmnt -no OPTIONS /
```

Resolve any errors and confirm the quota options appear. Stop Samba and other services that write to the root filesystem while initializing the quota file. The `-m` option checks the live root filesystem without remounting it read-only; writes during the scan can make recorded usage inaccurate. The backup accounts below must not exist or own files yet.

```bash
sudo systemctl stop smbd
sudo quotacheck -cum /
sudo quotaon -u /
sudo quotaon -u -p /
```

User quota for `/` must be **on**. `quotaon -p` may return a nonzero exit status even when it prints that quotas are on; check its output. If another command fails, do not continue or force the quota check; investigate the error first.

Create the backup accounts and directories on the host:

```bash
sudo adduser --system --group --no-create-home --shell /usr/sbin/nologin tm-jori
sudo adduser --system --group --no-create-home --shell /usr/sbin/nologin tm-chantal
sudo install -d -o tm-jori -g tm-jori -m 0700 /srv/timemachine/jori
sudo install -d -o tm-chantal -g tm-chantal -m 0700 /srv/timemachine/chantal
sudo setquota -u tm-jori 0 500G 0 0 /
sudo setquota -u tm-chantal 0 250G 0 0 /
sudo repquota -u /
```

`setquota` uses binary units: `500G` is 500 GiB. Zero soft and inode limits mean those limits are disabled. Check the hard block limits in the `hard` column.

Reboot, then verify quotas are still enabled and both limits remain in place:

```bash
sudo reboot
```

```bash
sudo quotaon -u -p /
sudo repquota -u /
```

An existing host Samba service may restart on boot; the new shares are not configured yet. Do not start backups if quota enforcement is off or a limit is missing.

Before starting either backup, verify that the hard limit blocks writes. Temporarily set each quota to 1 MiB and try to write 2 MiB:

```bash
sudo setquota -u tm-jori 0 1M 0 0 /
sudo setquota -u tm-chantal 0 1M 0 0 /
sudo runuser -u tm-jori -- dd if=/dev/zero of=/srv/timemachine/jori/quota-test bs=1M count=2 status=none
sudo runuser -u tm-chantal -- dd if=/dev/zero of=/srv/timemachine/chantal/quota-test bs=1M count=2 status=none
```

Both writes should fail with `Disk quota exceeded`. Remove the test files and restore the limits:

```bash
sudo rm -f /srv/timemachine/jori/quota-test /srv/timemachine/chantal/quota-test
sudo setquota -u tm-jori 0 500G 0 0 /
sudo setquota -u tm-chantal 0 250G 0 0 /
sudo repquota -u /
```

If either write succeeded or failed for another reason, resolve the problem before enabling the shares.

## 3. Install the container service

From `samba/`, build the image and install the host discovery and startup files:

```bash
sudo docker compose config --quiet
sudo docker compose build
sudo install -m 0644 avahi.service /etc/avahi/services/samba-timemachine.service
sudo install -m 0755 quota-check.sh /usr/local/sbin/samba-quota-check
sudo install -m 0644 samba-container.service /etc/systemd/system/samba-container.service
printf 'SAMBA_DIR="%s"\n' "$(pwd -P)" | sudo tee /etc/default/samba-container >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable --now avahi-daemon
sudo /usr/local/sbin/samba-quota-check
```

The Avahi file advertises the SMB service and both Time Machine shares. If `/etc/avahi/services/` already has a static Samba advertisement, remove or update that duplicate before starting the container.

The systemd unit runs the quota check before every container start. It requires the backup directories to be on `/`, owned by distinct backup users, and subject to enabled hard quotas no larger than those above. Docker's restart policy is deliberately disabled so a Docker daemon restart cannot bypass this check. Use `systemctl` to start, stop or restart the service; do not start it with `docker compose up` directly. If quotas are off, the media share is also unavailable until the check passes.

Stop and disable the host Samba service before starting the container on port 445:

```bash
sudo systemctl disable --now smbd
sudo systemctl enable --now samba-container
sudo systemctl status samba-container
```

The container reads `/etc/passwd` and `/etc/group` from the host, preserving user IDs for media permissions and quota accounting. Recreating the container on service restart picks up changes to those files. Docker stores Samba's account database in the persistent `samba-state` volume; it is separate from the host Samba database and must be retained across updates.

Set the container's Samba passwords. For `media`, use its current password if existing clients should keep working with their saved credentials:

```bash
sudo docker compose exec samba smbpasswd -a media
sudo docker compose exec samba smbpasswd -a tm-jori
sudo docker compose exec samba smbpasswd -a tm-chantal
```

Choose a separate password for each backup account. Passwords are not stored in this repository. Until the `media` password is set in the container, the existing share is unavailable to clients.

Check that all three shares work:

```bash
smbclient //localhost/pi-share -U media -c 'ls'
smbclient //localhost/TimeMachine-Jori -U tm-jori -c 'ls'
smbclient //localhost/TimeMachine-Chantal -U tm-chantal -c 'ls'
```

Each command should list its share after prompting for that account's Samba password. `pi-share` must remain read-only. Confirm the backup accounts cannot access each other's shares:

```bash
smbclient //localhost/TimeMachine-Chantal -U tm-jori -c 'ls'
smbclient //localhost/TimeMachine-Jori -U tm-chantal -c 'ls'
```

Both should report `NT_STATUS_ACCESS_DENIED`. If the service fails, inspect `sudo journalctl -u samba-container` and run `sudo /usr/local/sbin/samba-quota-check`.

After a reboot, verify the service, quota check and media share again:

```bash
sudo /usr/local/sbin/samba-quota-check
systemctl status samba-container
smbclient //localhost/pi-share -U media -c 'ls'
```

## 4. Set up the Macs

On each Mac, open **System Settings → General → Time Machine**, add the corresponding network disk, and sign in with its Samba account. Enable backup encryption and keep the password safe. If the share does not appear, first connect in Finder using **Go → Connect to Server** and `smb://pi501.local/TimeMachine-Jori` or `smb://pi501.local/TimeMachine-Chantal`.

After the first backup, restore a file to check it works. Monitor space and usage on pi501:

```bash
df -h /
sudo quota -v -u tm-jori
sudo quota -v -u tm-chantal
```

Keep another backup of irreplaceable data on a separate device or off-site.

## Updates and rollback

After changing `smb.conf` or the Dockerfile, rebuild the image and restart the service from `samba/`:

```bash
sudo docker compose build
sudo systemctl restart samba-container
```

Do not remove the Docker `samba-state` volume: it contains the Samba account database. If the checkout moves, update `/etc/default/samba-container` with the new absolute directory before restarting. If limits change, update both `smb.conf` and `quota-check.sh`, install the updated quota check, and apply the new host quotas.

To return to the original host Samba service, stop the container, remove its Avahi advertisement, then start the original service:

```bash
sudo systemctl disable --now samba-container
sudo rm /etc/avahi/services/samba-timemachine.service
sudo systemctl enable --now smbd
```

The host's original Samba configuration and media account database remain in place. Neither rollback nor a container update removes the media or backup files.
