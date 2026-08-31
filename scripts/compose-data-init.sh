#!/bin/sh
# compose-data-init.sh — one-shot init for the main stack (docker-compose.yml).
# Same ownership/seed logic as basic-data-init.sh, but only the dirs this stack mounts
# (no Grafana/Prometheus/Portainer; those live in docker-basic-compose.yml).
set -e

mkdir -p /mnt /mnt-am /mnt-backups /mnt-ota/packages
# A previous failed run may have left a *directory* here (Docker creates a dir for a
# missing bind-mount source); a dir makes [ -s ] true and breaks Alertmanager's file mount.
if [ ! -f /mnt-am/chirpstack-active.yml ]; then
  # Remove any leftover *directory* (Docker creates a dir for a missing bind-mount
  # source; a dir makes [ -s ] true and breaks Alertmanager's file mount).
  if [ -d /mnt-am/chirpstack-active.yml ]; then
    rm -rf /mnt-am/chirpstack-active.yml
  fi
  cp /src-am/alertmanager.yml /mnt-am/chirpstack-active.yml
fi
chown -R 1000:1000 /mnt /mnt-am /mnt-backups /mnt-ota
chmod 2775 /mnt /mnt-am /mnt-backups /mnt-ota /mnt-ota/packages
find /mnt -mindepth 1 -type d -exec chmod 2775 {} + 2>/dev/null || true
find /mnt -type f -exec chmod 664 {} + 2>/dev/null || true
find /mnt-am -mindepth 1 -type d -exec chmod 2775 {} + 2>/dev/null || true
find /mnt-am -type f -exec chmod 664 {} + 2>/dev/null || true
find /mnt-backups -mindepth 1 -type d -exec chmod 2775 {} + 2>/dev/null || true
find /mnt-backups -type f -exec chmod 664 {} + 2>/dev/null || true
