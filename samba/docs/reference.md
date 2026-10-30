# Samba reference

## Host requirements

- Raspberry Pi running Debian Bookworm or Trixie, with internet access and an ext4 root filesystem.
- At least **800 GiB free on `/`** for the configured limits. The backup directories must be on that filesystem.
- Rootful Docker with Compose and Buildx. Setup installs these and the other host dependencies if needed.
- TCP port 445 free during installation, and a terminal for the password prompts.

Setup refuses existing backup accounts or directories, existing quota configurations, and unrelated host service files. It preserves an existing `/srv/media` directory and its ownership; the `media` account must be able to read it.

## Shares

| Share                 | Samba account | Host directory             | Access     | Samba limit | Hard quota |
|-----------------------|---------------|----------------------------|------------|------------:|-----------:|
| `pi-share`            | `media`       | `/srv/media`               | Read-only  |           — |          — |
| `TimeMachine-Jori`    | `tm-jori`     | `/srv/timemachine/jori`    | Read/write |     480 GiB |    500 GiB |
| `TimeMachine-Chantal` | `tm-chantal`  | `/srv/timemachine/chantal` | Read/write |     240 GiB |    250 GiB |

The hard quota covers all files owned by the account on the root filesystem. Samba's limit is the size reported for the Time Machine share.

## Host files and services

| Item                                            | Purpose                                              |
|-------------------------------------------------|------------------------------------------------------|
| `samba-container.service`                       | Starts the container after the quota guard passes.   |
| `/etc/default/samba-container`                  | Stores the checkout's `samba` directory for systemd. |
| `/usr/local/sbin/samba-quota-check`             | Installed copy of the startup quota guard.           |
| `/etc/avahi/services/samba-timemachine.service` | Advertises Samba and Time Machine shares.            |
| `/etc/fstab.before-timemachine`                 | Original fstab saved during preparation.             |
| `/var/lib/homelab-samba-setup`                  | Setup progress markers.                              |
| Compose volume `samba-state`                    | Persistent Samba account database.                   |

Samba passwords are entered interactively and stored in the account database, outside Git. Backup files stay in the host directories.
