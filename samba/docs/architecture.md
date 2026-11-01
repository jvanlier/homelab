# How Samba storage works

Samba runs in a Docker container. The media directory is mounted read-only; each Time Machine directory is writable only by its own Samba account. The host's account IDs are available inside the container so filesystem ownership and quotas apply to those writes. Avahi on the host advertises the shares for discovery.

## Storage and quotas

The host enforces separate ext4 user quotas for the two backup accounts. A quota covers all files owned by that account on the root filesystem, so the limit still applies to writes outside Samba. Samba reports slightly smaller limits because its Time Machine size calculation is approximate.

The hard limits total 750 GiB. Setup requires at least 800 GiB free before creating them, but quotas do not reserve space: other data can still use the remaining capacity. The Pi had about 812 GiB free when the limits were chosen, leaving little room for backup history.

Preparation initializes quota accounting and updates the root mount options. Installation requires a reboot, checks that quotas are active, and tests that excess writes are blocked. Trixie currently warns that external ext4 quota files are deprecated.

## Startup guard

Systemd runs the quota guard before starting Samba. The guard checks the backup accounts, directory ownership, filesystem and hard limits. If a check fails, the whole container stays down, including the media share. The container has no Docker restart policy so that a Docker restart cannot bypass the guard.
