#!/usr/bin/env bash
set -eux

PATH=$PATH:/usr/local/bin:/bin

FN=backup/zigbee2mqtt.tar

running_container=$(docker compose ps --status running --quiet zigbee2mqtt)
restart_zigbee2mqtt() {
    if [ -n "${running_container}" ]; then
        docker compose start zigbee2mqtt
    fi
}
trap restart_zigbee2mqtt EXIT

if [ -n "${running_container}" ]; then
    docker compose stop zigbee2mqtt
fi

mkdir -p backup
tar -cf "${FN}" --exclude='zigbee2mqtt-data/log' zigbee2mqtt-data
restart_zigbee2mqtt
trap - EXIT

# Parallel bzip2:
pbzip2 -f "${FN}"

aws s3 cp "${FN}.bz2" s3://jori-homelab-backup/zigbee2mqtt/
rm "${FN}.bz2"
