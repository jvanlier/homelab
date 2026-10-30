Samba fileshare
=============

Sharing some media using Samba - not in docker.

For Mac backups on pi501, see [Time Machine setup](TIME_MACHINE.md).

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

Run `testparm` to ensure no syntax errors.

Add the SMB user (use the same password):

```
sudo smbpasswd -a media
```

Restart:

```
sudo systemctl restart smbd
```
