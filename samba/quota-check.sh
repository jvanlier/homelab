#!/bin/sh
set -eu

status=$(LC_ALL=C /usr/sbin/quotaon -u -p / 2>&1 || true)
if ! printf '%s\n' "$status" | grep -Eq ' is on[[:space:]]*$'; then
    echo "User quotas are not enabled on /: $status" >&2
    exit 1
fi

report=$(LC_ALL=C /usr/sbin/repquota -u -n -v /)
root_device=$(findmnt -n -o MAJ:MIN --target /)
media_uid=$(id -u media)
previous_uid=
for entry in tm-jori:524288000 tm-chantal:262144000; do
    user=${entry%%:*}
    max=${entry#*:}
    uid=$(id -u "$user")
    path=/srv/timemachine/${user#tm-}
    if [ "$uid" -eq 0 ] || [ "$uid" = "$media_uid" ] || [ "$uid" = "$previous_uid" ] ||
       [ "$(stat -c %u "$path")" != "$uid" ] ||
       [ "$(findmnt -n -o MAJ:MIN --target "$path")" != "$root_device" ]; then
        echo "Invalid account or filesystem for $user at $path" >&2
        exit 1
    fi
    previous_uid=$uid
    if ! printf '%s\n' "$report" | awk -v uid="$uid" -v max="$max" '
        $1 == "#" uid { found = 1; if ($5 > 0 && $5 <= max) ok = 1 }
        END { exit !(found && ok) }
    '; then
        echo "Missing or excessive hard quota for $user on /" >&2
        exit 1
    fi
done
