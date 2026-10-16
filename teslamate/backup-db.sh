e!/usr/bin/env bash
set -eux

PATH=$PATH:/usr/local/bin:/bin

FN=teslamate.sql

docker compose exec -T database pg_dump -U teslamate teslamate > ${FN}
# Parallel bzip2:
pbzip2 -f "${FN}"

aws s3 cp ${FN}.bz2 s3://jori-homelab-backup/teslamate/
rm ${FN}.bz2
