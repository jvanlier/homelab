#!/bin/sh
set -eu

DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
STATE=/var/lib/homelab-samba-setup
BACKUP=/etc/fstab.before-timemachine

fail() {
    echo "Error: $*" >&2
    exit 1
}

check_host() {
    [ "$(id -u)" -eq 0 ] || fail "Run this script with sudo"
    [ "$(findmnt -n -o FSTYPE -T /)" = ext4 ] || fail "The root filesystem must be ext4"
    getent passwd nobody >/dev/null || fail "Samba needs the nobody account"
    case "$DIR" in *[!a-zA-Z0-9_./-]*) fail "Unsupported character in checkout path: $DIR" ;; esac
}

install_dependencies() {
    apt-get update
    apt-get install -y --no-remove avahi-daemon quota smbclient iproute2 e2fsprogs util-linux ca-certificates curl
    if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1 || ! docker buildx version >/dev/null 2>&1; then
        candidate=$(apt-cache policy docker-compose-plugin | awk '/Candidate:/ {print $2}')
        if [ -z "$candidate" ] || [ "$candidate" = '(none)' ]; then
            # shellcheck source=/dev/null
            . /etc/os-release
            case "${VERSION_CODENAME:-}" in bookworm|trixie) ;; *) fail "Docker installation supports Bookworm and Trixie" ;; esac
            arch=$(dpkg --print-architecture)
            case "$arch" in arm64|armhf|amd64) ;; *) fail "Unsupported Docker architecture: $arch" ;; esac
            key=/etc/apt/keyrings/homelab-docker.asc
            source=/etc/apt/sources.list.d/homelab-docker.list
            [ ! -e "$key" ] && [ ! -e "$source" ] || fail "Inspect the existing homelab Docker repository files"
            install -d -m 0755 /etc/apt/keyrings
            tmp_key=$(mktemp)
            if ! curl -fsSL https://download.docker.com/linux/debian/gpg -o "$tmp_key"; then
                rm -f "$tmp_key"
                fail "Could not download the Docker repository key"
            fi
            install -m 0644 "$tmp_key" "$key"
            rm -f "$tmp_key"
            printf 'deb [arch=%s signed-by=%s] https://download.docker.com/linux/debian %s stable\n' \
                "$arch" "$key" "$VERSION_CODENAME" > "$source"
            apt-get update
        fi
        if command -v docker >/dev/null 2>&1; then
            if ! docker compose version >/dev/null 2>&1; then
                apt-get install -y --no-remove docker-compose-plugin
            fi
            if ! docker buildx version >/dev/null 2>&1; then
                apt-get install -y --no-remove docker-buildx-plugin
            fi
        else
            apt-get install -y --no-remove docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        fi
    fi
    systemctl enable --now docker
    check_docker
}

check_docker() {
    docker compose version >/dev/null
    docker buildx version >/dev/null
    options=$(docker info --format '{{json .SecurityOptions}}')
    case "$options" in *rootless*) fail "Rootless Docker remaps user IDs" ;; esac
}

ensure_media() {
    if ! getent passwd media >/dev/null; then
        adduser --system --group --no-create-home --shell /usr/sbin/nologin media
    fi
    if [ ! -e /srv/media ] && [ ! -L /srv/media ]; then
        install -d -o media -g "$(id -g media)" -m 0755 /srv/media
    fi
    [ -d /srv/media ] && [ ! -L /srv/media ] || fail "Inspect the existing /srv/media path"
    if ! runuser -u media -- test -r /srv/media || ! runuser -u media -- test -x /srv/media; then
        fail "The media account cannot read /srv/media; adjust its permissions"
    fi
}

prepare() {
    check_host
    if [ -f "$STATE/prepared" ]; then
        echo "Quotas are already prepared. Reboot, then run: sudo ./setup.sh install"
        return
    fi
    [ ! -e "$STATE" ] && [ ! -L "$STATE" ] || fail "An earlier preparation was interrupted; see the recovery instructions in docs/operations.md"
    [ ! -e "$BACKUP" ] && [ ! -L "$BACKUP" ] || fail "$BACKUP already exists; inspect it before proceeding"
    [ ! -L /etc/fstab ] || fail "/etc/fstab is a symlink; inspect it before proceeding"
    for user in tm-jori tm-chantal; do
        if id -u "$user" >/dev/null 2>&1; then
            fail "$user already exists; inspect the existing setup before proceeding"
        fi
    done
    for file in /aquota.user /quota.user /aquota.group /quota.group; do
        [ ! -e "$file" ] && [ ! -L "$file" ] || fail "Existing quota file: $file"
    done
    if [ -e /srv/timemachine ] || [ -L /srv/timemachine ]; then
        [ -d /srv/timemachine ] && [ ! -L /srv/timemachine ] || fail "Inspect /srv/timemachine before proceeding"
    fi
    for path in /srv/timemachine/jori /srv/timemachine/chantal; do
        [ ! -e "$path" ] && [ ! -L "$path" ] || fail "Backup directory already exists: $path"
    done
    available=$(LC_ALL=C df -Pk / | awk 'NR == 2 {print $4}')
    [ -n "$available" ] && [ "$available" -ge 838860800 ] || fail "At least 800 GiB must be free on / for the configured limits"
    install_dependencies
    status=$(LC_ALL=C quotaon -u -p / 2>&1 || true)
    if printf '%s\n' "$status" | grep -Eq ' is on([[:space:]]|$)'; then
        fail "User quotas are already on; inspect the existing setup"
    fi

    root_source=$(findmnt -n -o SOURCE -T /)
    if [ ! -b "$root_source" ]; then
        root_source=$(findmnt -n --fstab --evaluate -o SOURCE --target /)
    fi
    [ -b "$root_source" ] || fail "Cannot identify the root block device"
    root_device=$(findmnt -n -o MAJ:MIN -T /)
    [ "$(lsblk -n -d -o MAJ:MIN "$root_source")" = "$root_device" ] || fail "Root device does not match /etc/fstab"
    backup_parent=/srv
    [ ! -d /srv/timemachine ] || backup_parent=/srv/timemachine
    [ "$(findmnt -n -o MAJ:MIN -T "$backup_parent")" = "$root_device" ] || fail "Backup directories must be on the root filesystem"
    filesystem_info=$(tune2fs -l "$root_source")
    features=$(printf '%s\n' "$filesystem_info" | awk '/^Filesystem features:/ { $1=""; $2=""; print; found=1 } END { if (!found) exit 1 }')
    case " $features " in *" quota "*) fail "Root filesystem already has the ext4 quota feature" ;; esac

    df -h /

    umask 077
    tmp=$(mktemp /etc/fstab.samba.XXXXXX)
    trap 'rm -f "$tmp"' EXIT
    if ! awk '
        /^[[:space:]]*#/ || NF == 0 { print; next }
        $2 == "/" {
            count++
            if ($3 != "ext4" || $4 ~ /(^|,)(quota|noquota|usrquota|grpquota|prjquota|usrjquota=[^,]*|grpjquota=[^,]*|jqfmt=[^,]*)(,|$)/) exit 1
            if (!match($0, /^[[:space:]]*[^[:space:]]+[[:space:]]+\/[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+/)) exit 1
            print substr($0, 1, RLENGTH) ",usrjquota=aquota.user,jqfmt=vfsv0" substr($0, RLENGTH + 1)
            next
        }
        { print }
        END { if (count != 1) exit 1 }
    ' /etc/fstab > "$tmp"; then
        rm -f "$tmp"
        fail "Cannot safely update the root entry in /etc/fstab; see recovery instructions"
    fi
    chown --reference=/etc/fstab "$tmp"
    chmod --reference=/etc/fstab "$tmp"
    findmnt --verify --tab-file "$tmp"
    ensure_media
    mkdir "$STATE"
    read -r boot_id < /proc/sys/kernel/random/boot_id
    printf '%s\n' "$boot_id" > "$STATE/boot-id"
    cp -a /etc/fstab "$BACKUP"
    mv -f "$tmp" /etc/fstab
    trap - EXIT
    if ! mount -o remount /; then
        cp -a "$BACKUP" /etc/fstab
        fail "Could not remount root; the original fstab was restored"
    fi

    # The backup accounts do not exist during the live filesystem scan.
    quotacheck -cum /
    quotaon -u /
    for user in tm-jori tm-chantal; do
        adduser --system --group --no-create-home --shell /usr/sbin/nologin "$user"
        install -d -o "$user" -g "$user" -m 0700 "/srv/timemachine/${user#tm-}"
    done
    setquota -u tm-jori 0 500G 0 0 /
    setquota -u tm-chantal 0 250G 0 0 /
    "$DIR/quota-check.sh"
    touch "$STATE/prepared"
    echo "Quota preparation complete. Reboot, then run: sudo ./setup.sh install"
}

verify_quota() {
    for entry in tm-jori:500G tm-chantal:250G; do
        user=${entry%%:*}
        limit=${entry#*:}
        path=/srv/timemachine/${user#tm-}
        [ -z "$(find "$path" -mindepth 1 -maxdepth 1 -print -quit)" ] || fail "$path must be empty before the quota test"
        log=$(mktemp)
        setquota -u "$user" 0 1M 0 0 /
        if runuser -u "$user" -- env LC_ALL=C dd if=/dev/zero of="$path/quota-test" bs=1M count=2 status=none 2>"$log"; then
            result=failed
        elif grep -q 'Disk quota exceeded' "$log"; then
            result=ok
        else
            result=failed
        fi
        rm -f "$path/quota-test"
        setquota -u "$user" 0 "$limit" 0 0 /
        if [ "$result" != ok ]; then
            echo "Quota test for $user failed:" >&2
            awk '{print > "/dev/stderr"}' "$log"
            rm -f "$log"
            fail "Quota enforcement could not be verified"
        fi
        rm -f "$log"
    done
    "$DIR/quota-check.sh"
    touch "$STATE/quota-tested"
}

install_service() {
    check_host
    [ -f "$STATE/prepared" ] || fail "Run sudo ./setup.sh prepare first"
    check_docker
    [ -t 0 ] && [ -t 1 ] || fail "Run install in a terminal to set the Samba passwords"
    read -r before < "$STATE/boot-id"
    read -r current < /proc/sys/kernel/random/boot_id
    [ "$before" != "$current" ] || fail "Reboot before running install"
    "$DIR/quota-check.sh"
    if ! systemctl is-active --quiet samba-container; then
        listeners=$(ss -H -ltn 'sport = :445')
        [ -z "$listeners" ] || fail "TCP port 445 is in use; stop the existing SMB service before installing"
    fi
    [ -f "$STATE/quota-tested" ] || verify_quota
    if ! runuser -u media -- test -r /srv/media || ! runuser -u media -- test -x /srv/media; then
        fail "The media account cannot read /srv/media; adjust its permissions"
    fi

    # Refuse to replace unrelated host configuration on first installation.
    for pair in "avahi.service:/etc/avahi/services/samba-timemachine.service" \
                "quota-check.sh:/usr/local/sbin/samba-quota-check" \
                "samba-container.service:/etc/systemd/system/samba-container.service"; do
        source=${pair%%:*}
        target=${pair#*:}
        [ ! -L "$target" ] || fail "$target is a symlink"
        if [ -e "$target" ] && ! cmp -s "$DIR/$source" "$target"; then
            fail "$target already exists with different contents"
        fi
    done
    for file in /etc/avahi/services/*.service; do
        [ -f "$file" ] || continue
        [ "$file" = /etc/avahi/services/samba-timemachine.service ] && continue
        if grep -Eq '_smb\._tcp|_adisk\._tcp' "$file"; then
            fail "Inspect the existing Samba advertisement: $file"
        fi
    done
    expected=$(printf 'SAMBA_DIR="%s"' "$DIR")
    [ ! -L /etc/default/samba-container ] || fail "/etc/default/samba-container is a symlink"
    if [ -e /etc/default/samba-container ]; then
        printf '%s\n' "$expected" | cmp -s - /etc/default/samba-container ||
            fail "/etc/default/samba-container already exists with different contents"
    fi

    (cd "$DIR" && docker compose config --quiet && docker compose build)
    install -m 0644 "$DIR/avahi.service" /etc/avahi/services/samba-timemachine.service
    install -m 0755 "$DIR/quota-check.sh" /usr/local/sbin/samba-quota-check
    install -m 0644 "$DIR/samba-container.service" /etc/systemd/system/samba-container.service
    printf '%s\n' "$expected" > /etc/default/samba-container
    systemctl daemon-reload
    systemctl enable --now avahi-daemon
    systemctl enable --now samba-container

    # systemd starts Compose asynchronously; wait until the container can accept exec.
    ready=no
    attempt=0
    while [ "$attempt" -lt 12 ]; do
        if (cd "$DIR" && docker compose exec -T samba true) >/dev/null 2>&1; then
            ready=yes
            break
        fi
        attempt=$((attempt + 1))
        sleep 5
    done
    [ "$ready" = yes ] || fail "Samba did not start; check journalctl -u samba-container"
    users=$(cd "$DIR" && docker compose exec -T samba pdbedit -L)
    for user in media tm-jori tm-chantal; do
        if printf '%s\n' "$users" | awk -F: -v user="$user" '$1 == user {found=1} END {exit !found}'; then
            echo "Samba account $user already exists; keeping its password"
        else
            [ -t 0 ] && [ -t 1 ] || fail "A terminal is required to set the Samba passwords"
            if [ "$user" = media ]; then
                echo "Set the media Samba password (use the current password to keep existing clients working)"
            else
                echo "Set the Samba password for $user"
            fi
            (cd "$DIR" && docker compose exec samba smbpasswd -a "$user")
        fi
    done
    touch "$STATE/installed"
    echo "Samba is running. Verify the media share and set up Time Machine on each Mac."
}

case "${1:-}" in
    prepare) prepare ;;
    install) install_service ;;
    *) echo "Usage: sudo ./setup.sh prepare|install" >&2; exit 2 ;;
esac
