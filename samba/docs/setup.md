# Set up Samba and Time Machine

This guide sets up the media share and both Time Machine shares on a Raspberry Pi. Check the [host requirements](reference.md#host-requirements) before starting.

## Prepare the Pi

If you have existing media, place it in `/srv/media` yourself before setup, preserving ownership and permissions. The `media` account must be able to read it. On a fresh Pi, the script creates an empty directory. It does not move or modify `/media`.

If you are replacing a host Samba server, keep its configuration and account database until the container is verified. Stop the host service before the install step so port 445 is free.

Stop other workloads that write to `/`: preparation initializes quota accounting on the live filesystem. Then run from a terminal on the Pi:

```bash
cd /path/to/homelab/samba
sudo ./setup.sh prepare
sudo reboot
```

## Install Samba

After the Pi reboots, return to the repository and run:

```bash
cd /path/to/homelab/samba
sudo ./setup.sh install
```

Enter passwords for the three Samba accounts when prompted. For `media`, reuse the current password if existing clients should keep their saved credentials.

Trixie may print a deprecation notice for external quota files; installation checks that quota enforcement works after reboot. If setup stops, see [recovery](operations.md#recover-an-interrupted-setup).

## Connect and verify

Check the media share using the `media` password:

```bash
smbclient //localhost/pi-share -U media -c 'ls'
```

On each Mac, choose its [Time Machine share](reference.md#shares) in **System Settings → General → Time Machine**, sign in with its Samba account and enable backup encryption. If it does not appear, first connect in Finder to `smb://pi501.local/TimeMachine-Jori` or `smb://pi501.local/TimeMachine-Chantal`.

After the first backups, restore a file from each Mac. Check quotas and free space as described in [operations](operations.md#check-quotas-and-free-space). Keep another backup of irreplaceable data on a separate device or off-site.
