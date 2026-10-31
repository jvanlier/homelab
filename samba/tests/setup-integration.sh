#!/bin/sh
set -eu

DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
IMAGE=${1:-debian:bookworm-slim}

# A disposable privileged container provides an ext4 root for quota tests. Docker
# and systemd are stubbed inside the chroot; the host's filesystem is not used.
docker run -i --rm --privileged -v "$DIR:/repo:ro" "$IMAGE" sh -s <<'TEST'
set -eu
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq quota avahi-daemon smbclient iproute2 e2fsprogs util-linux curl >/dev/null
truncate -s 1024M /tmp/root.img
mkfs.ext4 -q -F /tmp/root.img
mkdir /mnt/root
mount -o loop /tmp/root.img /mnt/root
root=/mnt/root
cleanup() {
    umount -l "$root/proc" 2>/dev/null || true
    umount -l "$root/sys" 2>/dev/null || true
    umount -l "$root/dev" 2>/dev/null || true
    umount -l "$root" 2>/dev/null || true
}
trap cleanup EXIT
(tar -C / -cf - bin etc lib sbin usr var) | tar -C "$root" -xf -
mkdir -p "$root/dev" "$root/proc" "$root/sys" "$root/run" "$root/tmp" "$root/media" "$root/srv" "$root/work/samba" "$root/usr/local/bin"
chmod 1777 "$root/tmp"
cp -a /repo/. "$root/work/samba/"
mount --rbind /dev "$root/dev"
mount --make-rslave "$root/dev"
mount -t proc proc "$root/proc"
mount --bind /sys "$root/sys"
rootdev=$(findmnt -n -o SOURCE -T "$root")
printf '%s / ext4 defaults 0 0\n' "$rootdev" > "$root/etc/fstab"
printf 'old media stays here\n' > "$root/media/.example"
old_id=$(stat -c '%d:%i:%u:%g:%a' "$root/media/.example")

# Samba passwords are represented by account names, without storing secrets.
tee "$root/usr/bin/docker" >/dev/null <<'DOCKER'
#!/bin/sh
case "$1" in
    info) if [ -f /tmp/rootless ]; then echo '[name=rootless]'; else echo '[]'; fi ;;
    buildx) exit 0 ;;
    compose)
        if [ "${2:-}" = exec ] && [ "${3:-}" = -T ] && [ "${5:-}" = pdbedit ]; then
            [ ! -f /var/lib/homelab-samba-setup/fake-users ] || /bin/cat /var/lib/homelab-samba-setup/fake-users
        elif [ "${2:-}" = exec ] && [ "${4:-}" = smbpasswd ]; then
            echo "$6:123:Test" >> /var/lib/homelab-samba-setup/fake-users
        fi ;;
    *) exit 1 ;;
esac
DOCKER
tee "$root/usr/bin/systemctl" >/dev/null <<'SYSTEMCTL'
#!/bin/sh
if [ "$1" = is-active ]; then exit 1; fi
printf '%s\n' "$*" >> /tmp/systemctl-calls
SYSTEMCTL
printf '#!/bin/sh\nexit 0\n' > "$root/usr/bin/apt-get"
tee "$root/usr/local/bin/df" >/dev/null <<'DF'
#!/bin/sh
if [ "${1:-}" = -Pk ]; then
    printf 'Filesystem 1024-blocks Used Available Capacity Mounted\n/dev/loop 1000000000 1 900000000 1%% /\n'
else
    exec /usr/bin/df "$@"
fi
DF
tee "$root/usr/local/bin/ss" >/dev/null <<'SS'
#!/bin/sh
if [ -f /tmp/port445 ]; then echo 'LISTEN 0 32 0.0.0.0:445 0.0.0.0:*'; fi
exit 0
SS
chmod +x "$root/usr/bin/docker" "$root/usr/bin/systemctl" "$root/usr/bin/apt-get" "$root/usr/local/bin/df" "$root/usr/local/bin/ss"

# Existing backup data, rootless Docker and pre-existing quotas must be refused.
mkdir -p "$root/srv/timemachine/jori"
printf keep > "$root/srv/timemachine/jori/sentinel"
if chroot "$root" /work/samba/setup.sh prepare; then exit 1; fi
test -f "$root/srv/timemachine/jori/sentinel"
test ! -e "$root/var/lib/homelab-samba-setup"
rm "$root/srv/timemachine/jori/sentinel"
rmdir "$root/srv/timemachine/jori"
touch "$root/tmp/rootless"
if chroot "$root" /work/samba/setup.sh prepare; then exit 1; fi
rm "$root/tmp/rootless"
printf '%s / ext4 defaults,usrquota 0 0\n' "$rootdev" > "$root/etc/fstab"
if chroot "$root" /work/samba/setup.sh prepare; then exit 1; fi
grep -q 'defaults,usrquota' "$root/etc/fstab"
test ! -e "$root/var/lib/homelab-samba-setup"
test ! -e "$root/srv/media"

# An unreadable existing media directory must not be changed.
printf '%s / ext4 defaults 0 0\n' "$rootdev" > "$root/etc/fstab"
mkdir "$root/srv/media"
chmod 700 "$root/srv/media"
printf 'preserve' > "$root/srv/media/sentinel"
media_before=$(stat -c '%d:%i:%u:%g:%a' "$root/srv/media")
if chroot "$root" /work/samba/setup.sh prepare; then exit 1; fi
test "$(stat -c '%d:%i:%u:%g:%a' "$root/srv/media")" = "$media_before"
grep -q preserve "$root/srv/media/sentinel"
test ! -e "$root/var/lib/homelab-samba-setup"
chroot "$root" userdel media
if chroot "$root" getent group media >/dev/null; then chroot "$root" groupdel media; fi
rm "$root/srv/media/sentinel"
rmdir "$root/srv/media"

# Prepare a clean root filesystem with no media account or native Samba server.
chroot "$root" /work/samba/setup.sh prepare
grep -q 'usrjquota=aquota.user,jqfmt=vfsv0' "$root/etc/fstab"
grep -q 'defaults 0 0' "$root/etc/fstab.before-timemachine"
media_uid=$(chroot "$root" id -u media)
media_gid=$(chroot "$root" id -g media)
test "$(stat -c '%u' "$root/srv/media")" = "$media_uid"
test "$(stat -c '%d:%i:%u:%g:%a' "$root/media/.example")" = "$old_id"
chroot "$root" /work/samba/quota-check.sh
chroot "$root" /work/samba/setup.sh prepare

# Install requires a reboot, a terminal, a free SMB port and no conflicting unit.
if script -q -e -c "chroot $root /work/samba/setup.sh install" /dev/null </dev/null; then exit 1; fi
printf 'previous-boot\n' > "$root/var/lib/homelab-samba-setup/boot-id"
if chroot "$root" /work/samba/setup.sh install; then exit 1; fi
touch "$root/tmp/port445"
if script -q -e -c "chroot $root /work/samba/setup.sh install" /dev/null </dev/null; then exit 1; fi
rm "$root/tmp/port445"
mkdir -p "$root/etc/systemd/system"
printf 'preserve\n' > "$root/etc/systemd/system/samba-container.service"
if script -q -e -c "chroot $root /work/samba/setup.sh install" /dev/null </dev/null; then exit 1; fi
grep -q preserve "$root/etc/systemd/system/samba-container.service"
rm "$root/etc/systemd/system/samba-container.service"
printf 'do not overwrite' > "$root/tmp/default-target"
ln -s /tmp/default-target "$root/etc/default/samba-container"
if script -q -e -c "chroot $root /work/samba/setup.sh install" /dev/null </dev/null; then exit 1; fi
grep -q 'do not overwrite' "$root/tmp/default-target"
rm "$root/etc/default/samba-container"

# Installation and a retry preserve the user's existing media and passwords.
printf 'already in new location\n' > "$root/srv/media/.hidden"
chown "$media_uid:$media_gid" "$root/srv/media/.hidden"
chmod 751 "$root/srv/media"
new_id=$(stat -c '%d:%i:%u:%g:%a' "$root/srv/media")
script -q -e -c "chroot $root /work/samba/setup.sh install" /dev/null </dev/null
test -f "$root/var/lib/homelab-samba-setup/quota-tested"
test -f "$root/var/lib/homelab-samba-setup/installed"
grep -q 'already in new location' "$root/srv/media/.hidden"
test "$(stat -c '%d:%i:%u:%g:%a' "$root/srv/media")" = "$new_id"
test "$(stat -c '%d:%i:%u:%g:%a' "$root/media/.example")" = "$old_id"
test "$(wc -l < "$root/var/lib/homelab-samba-setup/fake-users")" -eq 3
if grep -E '(^| )smbd($| )' "$root/tmp/systemctl-calls"; then exit 1; fi
script -q -e -c "chroot $root /work/samba/setup.sh install" /dev/null </dev/null
test "$(wc -l < "$root/var/lib/homelab-samba-setup/fake-users")" -eq 3

# A readable directory populated before preparation is not chowned or replaced.
awk '/^ensure_media\(\) \{/ {copy=1} copy {print} copy && /^}$/ {exit}' /repo/setup.sh > /tmp/ensure-media.sh
. /tmp/ensure-media.sh
fail() { echo "$*" >&2; exit 1; }
adduser --system --group --no-create-home --shell /usr/sbin/nologin media
mkdir /srv/media
chmod 755 /srv/media
printf 'pre-existing' > /srv/media/.example
before=$(stat -c '%d:%i:%u:%g:%a' /srv/media)
ensure_media
test "$(stat -c '%d:%i:%u:%g:%a' /srv/media)" = "$before"
grep -q 'pre-existing' /srv/media/.example
echo 'Fresh ext4 setup, quota enforcement, untouched media and safe rerun passed'
TEST
