#!/usr/bin/env bash
set -euo pipefail

# arrdocker - VPN health check
# Verifies gluetun VPN connectivity and restarts if down.
# Designed to run via cron every 5 minutes.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LOG_PREFIX="[$(date '+%Y-%m-%d %H:%M:%S')] vpn-healthcheck:"

# Check if gluetun container is running
if ! docker inspect -f '{{.State.Running}}' gluetun 2>/dev/null | grep -q true; then
  echo "$LOG_PREFIX gluetun container is not running, starting stack..."
  docker compose -f "$PROJECT_DIR/docker-compose.yml" up -d gluetun
  sleep 15
fi

# Query gluetun's built-in health endpoint (returns JSON with "ip" field)
VPN_IP=$(docker exec gluetun wget -qO- --timeout=10 http://localhost:9999/v1/publicip/ip 2>/dev/null || echo "")

if [[ -z "$VPN_IP" || "$VPN_IP" == "null" ]]; then
  echo "$LOG_PREFIX VPN connection DOWN - no public IP returned. Restarting gluetun..."
  docker restart gluetun
  sleep 20

  # Verify recovery
  VPN_IP=$(docker exec gluetun wget -qO- --timeout=10 http://localhost:9999/v1/publicip/ip 2>/dev/null || echo "")
  if [[ -z "$VPN_IP" || "$VPN_IP" == "null" ]]; then
    echo "$LOG_PREFIX VPN still DOWN after restart. Manual intervention may be required."
    exit 1
  fi
fi

echo "$LOG_PREFIX VPN OK - public IP: $VPN_IP"
