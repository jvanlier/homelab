#!/usr/bin/env bash
set -eux

PATH=$PATH:/usr/local/bin:/bin

# Use nullglob so the pattern expands to nothing if no files match
shopt -s nullglob
backups=(config/backups/*.tar)
shopt -u nullglob

# Check if the array is empty
if [ ${#backups[@]} -eq 0 ]; then
    echo "No backup found"
    exit 1
fi

# Get the last backup from the sorted array
LAST_BACKUP="${backups[-1]}"
echo "Latest backup: $LAST_BACKUP"

# Write file to the same place each time
aws s3 cp ${LAST_BACKUP} s3://jori-homelab-backup/home-assistant/backup.tar
