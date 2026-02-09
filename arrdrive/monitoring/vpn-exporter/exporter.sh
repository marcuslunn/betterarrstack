#!/bin/sh
# Lightweight VPN metrics exporter for Prometheus
# Polls gluetun's API and verifies VPN via icanhazip.com IP comparison
# Serves metrics on port 9101

GLUETUN_API="http://host.docker.internal:8000"
IP_CHECK_URL="http://icanhazip.com"
PORT=9101
CHECK_INTERVAL=30
RESTART_COUNT_FILE="/tmp/vpn_restart_count"

while true; do
  # ── 1. Query gluetun's own public-IP API ──────────────────────────
  GLUETUN_RAW=$(wget -qO- --timeout=5 "$GLUETUN_API/v1/publicip/ip" 2>/dev/null || echo "")
  GLUETUN_IP=$(echo "$GLUETUN_RAW" | grep -oE '"public_ip":"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
  if ! echo "$GLUETUN_IP" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    GLUETUN_IP=""
  fi

  # ── 2. Host-side: direct request (no proxy) to icanhazip ─────────
  HOST_START=$(date +%s%N 2>/dev/null || date +%s)
  HOST_RESPONSE=$(wget -qO- --timeout=10 "$IP_CHECK_URL" 2>/dev/null) || true
  HOST_END=$(date +%s%N 2>/dev/null || date +%s)

  HOST_IP=$(echo "$HOST_RESPONSE" | tr -d '[:space:]')
  if ! echo "$HOST_IP" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    HOST_IP=""
  fi

  if echo "$HOST_START" | grep -qE '[0-9]{10,}'; then
    HOST_MS=$(( (HOST_END - HOST_START) / 1000000 ))
  else
    HOST_MS=$(( (HOST_END - HOST_START) * 1000 ))
  fi

  # ── 3. VPN-side: request via gluetun's HTTP proxy (port 8888) ───
  VPN_START=$(date +%s%N 2>/dev/null || date +%s)
  VPN_RESPONSE=$(wget -qO- --timeout=10 \
    -e "http_proxy=http://host.docker.internal:8888" \
    "$IP_CHECK_URL" 2>/dev/null) || true
  VPN_END=$(date +%s%N 2>/dev/null || date +%s)

  VPN_IP=$(echo "$VPN_RESPONSE" | tr -d '[:space:]')
  if ! echo "$VPN_IP" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    VPN_IP=""
  fi

  if echo "$VPN_START" | grep -qE '[0-9]{10,}'; then
    VPN_MS=$(( (VPN_END - VPN_START) / 1000000 ))
  else
    VPN_MS=$(( (VPN_END - VPN_START) * 1000 ))
  fi

  # ── 4. Determine VPN status and compare IPs ─────────────────────
  if [ -n "$VPN_IP" ]; then
    VPN_UP=1
  else
    VPN_UP=0
    COUNT=$(cat "$RESTART_COUNT_FILE" 2>/dev/null || echo "0")
    COUNT=$((COUNT + 1))
    echo "$COUNT" > "$RESTART_COUNT_FILE"
  fi

  RESTART_TOTAL=$(cat "$RESTART_COUNT_FILE" 2>/dev/null || echo "0")

  # VPN is working correctly if the VPN IP differs from the host IP
  if [ -n "$VPN_IP" ] && [ -n "$HOST_IP" ] && [ "$VPN_IP" != "$HOST_IP" ]; then
    IP_DIFFERENT=1
  else
    IP_DIFFERENT=0
  fi

  # ── 5. Get gluetun container uptime ──────────────────────────────
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

  # ── 6. Sanitise IPs for label values (fallback to "unknown") ─────
  GLUETUN_IP_LABEL=${GLUETUN_IP:-unknown}
  VPN_IP_LABEL=${VPN_IP:-unknown}
  HOST_IP_LABEL=${HOST_IP:-unknown}

  # ── 7. Build Prometheus metrics page ─────────────────────────────
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
# HELP vpn_ip_different Whether the VPN public IP differs from the host public IP (1 = protected, 0 = exposed or error).
# TYPE vpn_ip_different gauge
vpn_ip_different $IP_DIFFERENT
# HELP vpn_public_ip_info Informational metric exposing detected public IP addresses as labels. Value is always 1.
# TYPE vpn_public_ip_info gauge
vpn_public_ip_info{source="gluetun_api",ip="$GLUETUN_IP_LABEL"} 1
vpn_public_ip_info{source="vpn",ip="$VPN_IP_LABEL"} 1
vpn_public_ip_info{source="host",ip="$HOST_IP_LABEL"} 1
# HELP vpn_icanhazip_response_ms Response time in milliseconds for icanhazip.com via VPN.
# TYPE vpn_icanhazip_response_ms gauge
vpn_icanhazip_response_ms $VPN_MS
# HELP host_icanhazip_response_ms Response time in milliseconds for icanhazip.com directly (no VPN).
# TYPE host_icanhazip_response_ms gauge
host_icanhazip_response_ms $HOST_MS
EOF
)

  CONTENT_LENGTH=$(printf '%s' "$METRICS" | wc -c)
  RESPONSE=$(printf "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" "$CONTENT_LENGTH" "$METRICS")

  # Serve a single request then loop
  printf '%s' "$RESPONSE" | nc -l -p "$PORT" -w 5 >/dev/null 2>&1 || true

done
