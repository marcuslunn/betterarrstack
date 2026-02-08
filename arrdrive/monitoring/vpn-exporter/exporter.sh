#!/bin/sh
# Lightweight VPN metrics exporter for Prometheus
# Polls gluetun's API and serves metrics on port 9101

GLUETUN_API="http://host.docker.internal:9999"
PORT=9101
CHECK_INTERVAL=30

while true; do
  # Query gluetun health - check HTTP status and validate response contains an IP
  VPN_IP=$(wget -qO- --timeout=5 "$GLUETUN_API/v1/publicip/ip" 2>/dev/null || echo "")
  RESTART_COUNT_FILE="/tmp/vpn_restart_count"

  if echo "$VPN_IP" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; then
    VPN_UP=1
  else
    VPN_UP=0
    # Track restart attempts
    COUNT=$(cat "$RESTART_COUNT_FILE" 2>/dev/null || echo "0")
    COUNT=$((COUNT + 1))
    echo "$COUNT" > "$RESTART_COUNT_FILE"
  fi

  # Read cumulative restart count
  RESTART_TOTAL=$(cat "$RESTART_COUNT_FILE" 2>/dev/null || echo "0")

  # Get gluetun container uptime via Docker API (if available)
  UPTIME_SECONDS=0
  if command -v docker >/dev/null 2>&1; then
    STARTED=$(docker inspect -f '{{.State.StartedAt}}' gluetun 2>/dev/null || echo "")
    if [ -n "$STARTED" ]; then
      START_EPOCH=$(date -d "$STARTED" +%s 2>/dev/null || echo "0")
      NOW_EPOCH=$(date +%s)
      if [ "$START_EPOCH" -gt 0 ]; then
        UPTIME_SECONDS=$((NOW_EPOCH - START_EPOCH))
      fi
    fi
  fi

  # Build Prometheus metrics page
  METRICS=$(cat <<EOF
# HELP vpn_status Whether the VPN tunnel is up (1) or down (0).
# TYPE vpn_status gauge
vpn_status $VPN_UP
# HELP vpn_connection_failures_total Cumulative count of VPN connectivity failures detected.
# TYPE vpn_connection_failures_total counter
vpn_connection_failures_total $RESTART_TOTAL
# HELP vpn_uptime_seconds Seconds since the gluetun container last started.
# TYPE vpn_uptime_seconds gauge
vpn_uptime_seconds $UPTIME_SECONDS
EOF
)

  CONTENT_LENGTH=$(printf '%s' "$METRICS" | wc -c)
  RESPONSE=$(printf "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" "$CONTENT_LENGTH" "$METRICS")

  # Serve a single request then loop
  printf '%s' "$RESPONSE" | nc -l -p "$PORT" -w 5 >/dev/null 2>&1 || true

done
