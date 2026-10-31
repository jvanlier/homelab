Samba fileshare
=============

Sharing some media using Samba - not in docker.

Update: actually, not quite sure if unix user `media` needs to be added since we also add the SMB user.

```bash
sudo adduser media
mkdir -p /media
sudo chown media:media /media

sudo apt-get install samba samba-common-bin
```

Add the following to `/etc/samba/smb.conf` and remove the default share definitions:

```
[pi-share]
path = /media
browseable = yes
read only = yes
guest ok = no
valid users = media
```

Add the SMB user (use the same password):

```bash
sudo smbpasswd -a media
```



### Mac Time Machine backup

Create the mount point, then mount a dedicated, capacity-limited filesystem there or enforce an equivalent filesystem quota. Do not place Time Machine backups on the host filesystem shared with Home Assistant or the operating system.
```bash
sudo install -d -m 0755 /srv/time-machine
```

After mounting the dedicated filesystem at `/srv/time-machine`, set its ownership and permissions:

```bash
sudo adduser --disabled-password --gecos "" time-machine
sudo install -d -o time-machine -g time-machine -m 0700 /srv/time-machine
sudo smbpasswd -a time-machine
```

Add this second share to `/etc/samba/smb.conf`:

```
[time-machine]
path = /srv/time-machine
browseable = yes
read only = no
guest ok = no
valid users = time-machine
vfs objects = catia fruit streams_xattr
fruit:time machine = yes
fruit:time machine max size = 1T
```

Use `time-machine` and its SMB password when selecting the network disk in macOS Time Machine.

Replace `1T` with the capacity of the dedicated Time Machine filesystem or quota. This limits the size reported to Time Machine; the dedicated filesystem or quota provides the actual enforcement.

Validate the complete configuration, then restart Samba:

```bash
sudo testparm
sudo systemctl restart smbd
```
