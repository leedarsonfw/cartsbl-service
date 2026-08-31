#!/bin/sh
# basic-data-init.sh — one-shot init for the monitoring/basic stack (docker-basic-compose.yml).
# Runs in the basic-data-init container (host network namespace, postgres:14-alpine):
#   1. Creates + fixes ownership/permissions of the host data dirs (official image UIDs:
#      Prometheus nobody=65534, Grafana=472, ChirpStack rules dir=1000, Portainer root).
#   2. Seeds /mnt/alertmanager-sync/chirpstack-active.yml from the static alertmanager config
#      (ChirpStack later overwrites it from UI/DB rules).
#   3. Detects the host primary NIC MAC and persists CHIRPSTACK_PRIMARY_MAC into /mnt/service/.env.
#   4. Renders prometheus.yml from /src/prometheus-template.yml (PLACEHOLDER_MAC_ADDRESS).
echo "basic-data-init: script started" >&2
set -e

mkdir -p /mnt/prometheus /mnt/grafana /mnt/portainer /mnt/prometheus-rules /mnt/alertmanager-sync \
         /mnt/chirpstack-backups /mnt/system_ota/packages
# A previous failed run may have left a *directory* at this path (Docker creates a dir for a
# missing bind-mount source). A dir makes [ -s ] true (skipping the seed) AND breaks Alertmanager's
# file mount ("not a directory"). Remove any non-regular file, then seed if absent.
if [ ! -f /mnt/alertmanager-sync/chirpstack-active.yml ]; then
  # Remove any leftover *directory* (Docker creates a dir for a missing bind-mount source,
  # and a dir makes [ -s ] true, skipping the seed, AND breaks Alertmanager's file mount).
  # Use rm -rf: a non-empty dir would make rmdir fail and cp would copy *into* the dir.
  if [ -d /mnt/alertmanager-sync/chirpstack-active.yml ]; then
    rm -rf /mnt/alertmanager-sync/chirpstack-active.yml
  fi
  cp /src/alertmanager/alertmanager.yml /mnt/alertmanager-sync/chirpstack-active.yml
fi
chown -R 65534:65534 /mnt/prometheus
chown -R 472:472 /mnt/grafana
chown -R 0:0 /mnt/portainer
chown -R 1000:1000 /mnt/prometheus-rules
chown -R 1000:1000 /mnt/alertmanager-sync
chown -R 1000:1000 /mnt/chirpstack-backups
chown -R 1000:1000 /mnt/system_ota
chmod 2775 /mnt/prometheus-rules
chmod 2775 /mnt/alertmanager-sync
chmod 2775 /mnt/chirpstack-backups
chmod 2775 /mnt/system_ota /mnt/system_ota/packages
find /mnt/prometheus-rules -mindepth 1 -type d -exec chmod 2775 {} + 2>/dev/null || true
find /mnt/prometheus-rules -type f -exec chmod 664 {} + 2>/dev/null || true
find /mnt/alertmanager-sync -mindepth 1 -type d -exec chmod 2775 {} + 2>/dev/null || true
find /mnt/alertmanager-sync -type f -exec chmod 664 {} + 2>/dev/null || true
find /mnt/chirpstack-backups -mindepth 1 -type d -exec chmod 2775 {} + 2>/dev/null || true
find /mnt/chirpstack-backups -type f -exec chmod 664 {} + 2>/dev/null || true
find /mnt/system_ota -mindepth 1 -type d -exec chmod 2775 {} + 2>/dev/null || true
find /mnt/system_ota -type f -exec chmod 664 {} + 2>/dev/null || true

# Detect the host primary MAC (host network namespace -> /sys/class/net and /proc/net/route are the host's).
host_mac=""
set +e
# 1) Prefer physical + operstate=up interfaces first (best match for "device real MAC").
for p in /sys/class/net/*/address; do
  [ -f "$p" ] || continue
  iface=$(basename "$(dirname "$p")")
  case "$iface" in lo|docker*|br-*|veth*|virbr*|tun*|tap*|wg*) continue ;; esac
  [ -e "/sys/class/net/$iface/device" ] || continue
  [ "$(cat "/sys/class/net/$iface/operstate" 2>/dev/null)" = "up" ] || continue
  m=$(cat "$p" 2>/dev/null | tr -d '\r' | tr '[:upper:]' '[:lower:]')
  if [ -n "$m" ] && [ "$m" != "00:00:00:00:00:00" ] && echo "$m" | grep -qE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'; then
    host_mac="$m"
    break
  fi
done
# 2) Next, try default-route interface(s) but still skip virtual ones.
if [ -z "$host_mac" ]; then
  for iface in $(awk 'NR>1 && $2=="00000000" {print $1}' /proc/net/route 2>/dev/null | sort -u); do
    [ -z "$iface" ] && continue
    case "$iface" in lo|docker*|br-*|veth*|virbr*|tun*|tap*|wg*) continue ;; esac
    addr="/sys/class/net/$iface/address"
    [ -f "$addr" ] || continue
    m=$(cat "$addr" 2>/dev/null | tr -d '\r' | tr '[:upper:]' '[:lower:]')
    if [ -n "$m" ] && [ "$m" != "00:00:00:00:00:00" ] && echo "$m" | grep -qE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'; then
      host_mac="$m"
      break
    fi
  done
fi
# 3) Final fallback: first non-virtual NIC MAC.
if [ -z "$host_mac" ]; then
  for p in /sys/class/net/*/address; do
    [ -f "$p" ] || continue
    iface=$(basename "$(dirname "$p")")
    case "$iface" in lo|docker*|br-*|veth*|virbr*|tun*|tap*|wg*) continue ;; esac
    m=$(cat "$p" 2>/dev/null | tr -d '\r' | tr '[:upper:]' '[:lower:]')
    if [ -n "$m" ] && [ "$m" != "00:00:00:00:00:00" ] && echo "$m" | grep -qE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'; then
      host_mac="$m"
      break
    fi
  done
fi
set -e

[ -n "$host_mac" ] || host_mac="unknown"
echo "Detected MAC: $host_mac"
if [ "$host_mac" != "unknown" ]; then
  dotenv=/mnt/service/.env
  if [ -f "$dotenv" ] && grep -q '^CHIRPSTACK_PRIMARY_MAC=' "$dotenv" 2>/dev/null; then
    sed -i "s/^CHIRPSTACK_PRIMARY_MAC=.*/CHIRPSTACK_PRIMARY_MAC=$host_mac/" "$dotenv"
  else
    echo "CHIRPSTACK_PRIMARY_MAC=$host_mac" >> "$dotenv"
  fi
fi
# Select broker scrape job by deployment mode:
#   ONE_NODE=true  -> single-node: eclipse-mosquitto + mosquitto-exporter ($SYS/broker/#)
#   otherwise      -> cluster: emqx, scrape its native /api/v5/prometheus/stats
# The other broker job block is stripped from the rendered prometheus.yml so Prometheus
# only ever sees the job that actually produces data.
mode=cluster
if grep -q '^ONE_NODE=true' /mnt/service/.env 2>/dev/null; then
  mode=single
fi
# EMQX HTTP/dashboard listener port (docker-stack publishes it per node, host mode).
emqx_web_port=$(grep '^EMQX_WEB_PORT=' /mnt/service/.env 2>/dev/null | cut -d= -f2)
emqx_web_port=${emqx_web_port:-18083}
src=/src/prometheus-template.yml
if [ "$mode" = "single" ]; then
  # Drop the EMQX job block (no EMQX in single-node).
  sed '/^  # BEGIN broker-job-emqx/,/^  # END broker-job-emqx/d' "$src" > /tmp/prometheus.yml
else
  # Drop the mosquitto-exporter job block (cluster broker is EMQX, no $SYS data).
  sed '/^  # BEGIN broker-job-mosquitto/,/^  # END broker-job-mosquitto/d' "$src" > /tmp/prometheus.yml
fi
# Docker creates a DIRECTORY for a missing bind-mount source on first `up`. A leftover dir at
# /mnt/prometheus/prometheus.yml would break the render redirect below AND Prometheus's file
# mount ("mounting a directory onto a file"). Remove any non-regular file first.
if [ -e /mnt/prometheus/prometheus.yml ] && [ ! -f /mnt/prometheus/prometheus.yml ]; then
  rm -rf /mnt/prometheus/prometheus.yml
fi
awk -v m="$host_mac" -v p="$emqx_web_port" \
    '{gsub(/PLACEHOLDER_MAC_ADDRESS/, m); gsub(/PLACEHOLDER_EMQX_WEB_PORT/, p); print}' \
    /tmp/prometheus.yml > /mnt/prometheus/prometheus.yml
cat /mnt/prometheus/prometheus.yml
