# Time Machine on pi501

These instructions add two Time Machine shares to pi501's existing Samba server. Backups live on the ext4 root filesystem (`/dev/sda2`), with a separate Linux and Samba account for each Mac.

| Mac     | Share                 | Samba-reported limit | Hard user quota |
|---------|-----------------------|---------------------:|----------------:|
| Jori    | `TimeMachine-Jori`    |              480 GiB |         500 GiB |
| Chantal | `TimeMachine-Chantal` |              240 GiB |         250 GiB |

The Samba limit tells Time Machine when to start reclaiming space; the filesystem quota enforces the hard limit. Samba's calculation is approximate, so its limit is set slightly lower. These quotas apply to **all files owned by each backup account on the root filesystem**, not just files in the share. Keep the accounts dedicated to backups.

The Pi had about 812 GiB free when this was planned. If both quotas fill, that leaves roughly 62 GiB for the system and other files. The initial backups may be smaller than the space used on the Macs, but these limits leave little room for backup history. Check free space and quota usage regularly.

## 1. Prepare pi501

Run these commands on pi501:

```bash
findmnt -no SOURCE,FSTYPE,OPTIONS /
df -h /
smbd --version
sudo apt-get update
sudo apt-get install samba samba-vfs-modules smbclient avahi-daemon quota
```

Confirm that `/` is the expected ext4 filesystem and has enough free space. These instructions assume that user quotas are not already configured on it. Check for existing quotas and ext4's built-in quota feature:

```bash
sudo quotaon -u -p /
sudo tune2fs -l /dev/sda2 | grep 'Filesystem features'
findmnt --fstab -no OPTIONS /
sudo find / -maxdepth 1 \( -name aquota.user -o -name quota.user \) -ls
```

If user quotas are already on, the filesystem features include `quota`, the root fstab options already configure quotas, or either quota file exists, stop here and inspect the existing setup before proceeding. The steps below create a new external quota file and must not replace an existing quota configuration.

Use a Samba version with the Time Machine rename fix. For Samba 4.22, use 4.22.6 or newer; for 4.23, use 4.23.3 or newer. Samba 4.8–4.21 also needs an extra setting in step 3. See the [Samba Time Machine guidance](https://wiki.samba.org/index.php/Configure_Samba_to_Work_Better_with_Mac_OS_X) for version details.

## 2. Enable and verify user quotas

Back up `/etc/fstab`, then edit it:

```bash
sudo cp /etc/fstab /etc/fstab.before-timemachine
sudo nano /etc/fstab
```

On the **existing line whose mount point is `/`**, append `usrjquota=aquota.user,jqfmt=vfsv0` to its comma-separated mount options. Keep its existing device identifier, options and other fields. For example, if the options were `defaults,noatime`, they become:

```text
defaults,noatime,usrjquota=aquota.user,jqfmt=vfsv0
```

Do not add a second root filesystem line. Validate the file and remount `/`:

```bash
sudo findmnt --verify --verbose
sudo mount -o remount /
findmnt -no OPTIONS /
```

Resolve any errors before proceeding. Confirm that the quota options appear in the mount options. Stop Samba and other services that write to the root filesystem while initializing the quota file. The `-m` option checks the live root filesystem without remounting it read-only; other writes during the scan can make the recorded usage inaccurate. The backup accounts below must not exist or own files yet.

```bash
sudo systemctl stop smbd
sudo quotacheck -cum /
sudo quotaon -u /
sudo quotaon -u -p /
```

User quota for `/` must be **on**. `quotaon -p` may return a nonzero exit status even when it prints that quotas are on; check its output. If another command fails, do not continue or force the quota check; investigate the error first.

Create the dedicated accounts and directories:

```bash
sudo adduser --system --group --no-create-home --shell /usr/sbin/nologin tm-jori
sudo adduser --system --group --no-create-home --shell /usr/sbin/nologin tm-chantal
sudo install -d -o tm-jori -g tm-jori -m 0700 /srv/timemachine/jori
sudo install -d -o tm-chantal -g tm-chantal -m 0700 /srv/timemachine/chantal
sudo smbpasswd -a tm-jori
sudo smbpasswd -a tm-chantal
```

Choose a separate Samba password for each account. Set the hard quotas and check them:

```bash
sudo setquota -u tm-jori 0 500G 0 0 /
sudo setquota -u tm-chantal 0 250G 0 0 /
sudo repquota -u /
```

`setquota` uses binary units: `500G` is 500 GiB. Zero soft and inode limits mean those limits are disabled. The hard block limits are the numbers in the `hard` column.

Reboot, then verify that user quotas are still on and both hard limits remain in place:

```bash
sudo reboot
```

```bash
sudo quotaon -u -p /
sudo repquota -u /
```

Do not start backups if quota enforcement is off or either limit is missing. An existing Samba service may have restarted on boot; the new shares are not configured yet.

To verify that the hard limit actually blocks writes, temporarily give each new account a 1 MiB quota and try to write 2 MiB. Do this **before starting either backup**:

```bash
sudo setquota -u tm-jori 0 1M 0 0 /
sudo setquota -u tm-chantal 0 1M 0 0 /
sudo runuser -u tm-jori -- dd if=/dev/zero of=/srv/timemachine/jori/quota-test bs=1M count=2 status=none
sudo runuser -u tm-chantal -- dd if=/dev/zero of=/srv/timemachine/chantal/quota-test bs=1M count=2 status=none
```

Both writes should fail with `Disk quota exceeded`. Remove the test files and restore the intended limits:

```bash
sudo rm -f /srv/timemachine/jori/quota-test /srv/timemachine/chantal/quota-test
sudo setquota -u tm-jori 0 500G 0 0 /
sudo setquota -u tm-chantal 0 250G 0 0 /
sudo repquota -u /
```

If either write succeeded or failed for another reason, resolve the problem before enabling the shares.

## 3. Configure Samba

Back up the current configuration and edit it:

```bash
sudo cp /etc/samba/smb.conf /etc/samba/smb.conf.before-timemachine
sudo nano /etc/samba/smb.conf
```

Add these lines to the existing `[global]` section:

```ini
vfs objects = fruit streams_xattr
fruit:metadata = stream
```

If there is already a `vfs objects` setting, incorporate the modules into the existing configuration instead of adding a duplicate line. A per-share `vfs objects` setting overrides the global one. Enabling `fruit` globally also ensures the Apple SMB extensions are available when a Mac connects to the existing media share first.

For Samba 4.8–4.21, also add `fruit:posix_rename = yes` to `[global]`. Do not add that setting for newer releases.

Append the shares, leaving the existing `pi-share` intact:

```ini
[TimeMachine-Jori]
path = /srv/timemachine/jori
browseable = yes
read only = no
guest ok = no
valid users = tm-jori
fruit:time machine = yes
fruit:time machine max size = 480G

[TimeMachine-Chantal]
path = /srv/timemachine/chantal
browseable = yes
read only = no
guest ok = no
valid users = tm-chantal
fruit:time machine = yes
fruit:time machine max size = 240G
```

Validate the complete configuration:

```bash
sudo testparm
```

To prevent Samba from starting without user quotas, add a systemd override:

```bash
sudo systemctl edit smbd
```

Enter the following in the editor:

```ini
[Unit]
After=quotaon.service

[Service]
ExecStartPre=/bin/sh -c "LC_ALL=C /usr/sbin/quotaon -u -p / 2>&1 | grep -Fq ' is on'"
```

This also blocks the existing media share if quotas are off. Save the override, then restart Samba and check the shares:

```bash
sudo systemctl restart smbd
sudo systemctl enable --now avahi-daemon
smbclient //localhost/TimeMachine-Jori -U tm-jori -c 'ls'
smbclient //localhost/TimeMachine-Chantal -U tm-chantal -c 'ls'
```

Each `smbclient` command should list its share after prompting for that account's Samba password. Verify that each account is denied access to the other share:

```bash
smbclient //localhost/TimeMachine-Chantal -U tm-jori -c 'ls'
smbclient //localhost/TimeMachine-Jori -U tm-chantal -c 'ls'
```

Both commands should report `NT_STATUS_ACCESS_DENIED`. If Samba fails to start, check `sudo journalctl -u smbd`, the quota status and the installed Samba version.

## 4. Set up the Macs

On each Mac, open **System Settings → General → Time Machine**, add the corresponding network disk, and sign in with its Samba account. Enable backup encryption and keep the password safe. If the share does not appear, first connect in Finder using **Go → Connect to Server** and `smb://pi501.local/TimeMachine-Jori` or `smb://pi501.local/TimeMachine-Chantal`.

After the first backup, restore a file to check it works. Monitor space and usage on pi501:

```bash
df -h /
sudo quota -v -u tm-jori
sudo quota -v -u tm-chantal
```

If backups run out of room or the remaining Pi space becomes too small, move them to a larger dedicated disk. Keep another backup of irreplaceable data on a separate device or off-site.
