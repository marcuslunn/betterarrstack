#!/bin/sh
# Lightweight VPN metrics exporter for Prometheus
# Polls gluetun's API and verifies VPN via icanhazip.com IP comparison
# Serves metrics on port 9101

GLUETUN_API="http://host.docker.internal:8000"
IP_CHECK_URL="https://icanhazip.com"
PORT=9101
CHECK_INTERVAL=30
RESTART_COUNT_FILE="/tmp/vpn_restart_count"
HOST_IP_FILE="/tmp/host_public_ip"

# ── Fetch the host's real public IP once at startup ─────────────────
# This runs without VPN so we know the "bare" IP to compare against.
fetch_host_ip() {
  HOST_IP=$(wget -qO- --timeout=10 "$IP_CHECK_URL" 2>/dev/null | tr -d '[:space:]')
  if echo "$HOST_IP" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "$HOST_IP" > "$HOST_IP_FILE"
  fi
}

# Grab host IP at startup (the exporter container is NOT routed through gluetun)
fetch_host_ip

while true; do
  # ── 1. Query gluetun's own public-IP API ──────────────────────────
  VPN_RAW=$(wget -qO- --timeout=5 "$GLUETUN_API/v1/publicip/ip" 2>/dev/null || echo "")
  # Response is JSON: {"public_ip":"1.2.3.4", ...} — extract the IP
  VPN_IP=$(echo "$VPN_RAW" | grep -oE '"public_ip":"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')

  if echo "$VPN_IP" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    VPN_UP=1
  else
    VPN_UP=0
    # Track failure count
    COUNT=$(cat "$RESTART_COUNT_FILE" 2>/dev/null || echo "0")
    COUNT=$((COUNT + 1))
    echo "$COUNT" > "$RESTART_COUNT_FILE"
  fi

  RESTART_TOTAL=$(cat "$RESTART_COUNT_FILE" 2>/dev/null || echo "0")

  # ── 2. Independent icanhazip.com check through gluetun ────────────
  # We curl through gluetun's HTTP proxy to get the VPN-side public IP
  # and also curl directly for the host-side IP.

  # -- VPN-side: ask gluetun's HTTP proxy (port 8888) to reach icanhazip --
  VPN_START=$(date +%s%N 2>/dev/null || date +%s)
  VPN_ICANHAZIP_RESPONSE=$(wget -qO- -S --timeout=10 \
    -e "http_proxy=http://host.docker.internal:8888" \
    "$IP_CHECK_URL" 2>&1) || true
  VPN_END=$(date +%s%N 2>/dev/null || date +%s)

  # Extract status code from wget -S output (looks like "  HTTP/1.1 200 OK")
  VPN_ICANHAZIP_STATUS=$(echo "$VPN_ICANHAZIP_RESPONSE" | grep -oE 'HTTP/[0-9.]+ [0-9]+' | tail -1 | awk '{print $2}')
  VPN_ICANHAZIP_STATUS=${VPN_ICANHAZIP_STATUS:-0}

  # Extract the IP (last line of successful output, stripped)
  VPN_ICANHAZIP_IP=$(echo "$VPN_ICANHAZIP_RESPONSE" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tail -1)
  VPN_ICANHAZIP_IP=${VPN_ICANHAZIP_IP:-""}

  # Calculate response time in milliseconds
  if echo "$VPN_START" | grep -qE '[0-9]{10,}'; then
    VPN_ICANHAZIP_MS=$(( (VPN_END - VPN_START) / 1000000 ))
  else
    VPN_ICANHAZIP_MS=$(( (VPN_END - VPN_START) * 1000 ))
  fi

  # -- Host-side: direct request (no proxy) to icanhazip --
  HOST_START=$(date +%s%N 2>/dev/null || date +%s)
  HOST_ICANHAZIP_RESPONSE=$(wget -qO- -S --timeout=10 "$IP_CHECK_URL" 2>&1) || true
  HOST_END=$(date +%s%N 2>/dev/null || date +%s)

  HOST_ICANHAZIP_STATUS=$(echo "$HOST_ICANHAZIP_RESPONSE" | grep -oE 'HTTP/[0-9.]+ [0-9]+' | tail -1 | awk '{print $2}')
  HOST_ICANHAZIP_STATUS=${HOST_ICANHAZIP_STATUS:-0}

  HOST_ICANHAZIP_IP=$(echo "$HOST_ICANHAZIP_RESPONSE" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tail -1)
  HOST_ICANHAZIP_IP=${HOST_ICANHAZIP_IP:-""}

  if echo "$HOST_START" | grep -qE '[0-9]{10,}'; then
    HOST_ICANHAZIP_MS=$(( (HOST_END - HOST_START) / 1000000 ))
  else
    HOST_ICANHAZIP_MS=$(( (HOST_END - HOST_START) * 1000 ))
  fi

  # Update cached host IP if we got a valid one
  if echo "$HOST_ICANHAZIP_IP" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "$HOST_ICANHAZIP_IP" > "$HOST_IP_FILE"
  fi
  CACHED_HOST_IP=$(cat "$HOST_IP_FILE" 2>/dev/null || echo "")

  # ── 3. Compare IPs ───────────────────────────────────────────────
  # VPN is working correctly if the gluetun API IP differs from the host IP
  if [ -n "$VPN_IP" ] && [ -n "$CACHED_HOST_IP" ] && [ "$VPN_IP" != "$CACHED_HOST_IP" ]; then
    IP_DIFFERENT=1
  else
    IP_DIFFERENT=0
  fi

  # ── 4. Get gluetun container uptime ──────────────────────────────
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

  # ── 5. Sanitise IPs for label values (fallback to "unknown") ─────
  VPN_IP_LABEL=${VPN_IP:-unknown}
  VPN_ICANHAZIP_IP_LABEL=${VPN_ICANHAZIP_IP:-unknown}
  HOST_ICANHAZIP_IP_LABEL=${HOST_ICANHAZIP_IP:-unknown}

  # ── 6. Build Prometheus metrics page ─────────────────────────────
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
vpn_public_ip_info{source="gluetun_api",ip="$VPN_IP_LABEL"} 1
vpn_public_ip_info{source="icanhazip_vpn",ip="$VPN_ICANHAZIP_IP_LABEL"} 1
vpn_public_ip_info{source="icanhazip_host",ip="$HOST_ICANHAZIP_IP_LABEL"} 1
# HELP vpn_icanhazip_status_code HTTP status code from icanhazip.com via VPN.
# TYPE vpn_icanhazip_status_code gauge
vpn_icanhazip_status_code $VPN_ICANHAZIP_STATUS
# HELP vpn_icanhazip_response_ms Response time in milliseconds for icanhazip.com via VPN.
# TYPE vpn_icanhazip_response_ms gauge
vpn_icanhazip_response_ms $VPN_ICANHAZIP_MS
# HELP host_icanhazip_status_code HTTP status code from icanhazip.com directly (no VPN).
# TYPE host_icanhazip_status_code gauge
host_icanhazip_status_code $HOST_ICANHAZIP_STATUS
# HELP host_icanhazip_response_ms Response time in milliseconds for icanhazip.com directly (no VPN).
# TYPE host_icanhazip_response_ms gauge
host_icanhazip_response_ms $HOST_ICANHAZIP_MS
EOF
)

  CONTENT_LENGTH=$(printf '%s' "$METRICS" | wc -c)
  RESPONSE=$(printf "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" "$CONTENT_LENGTH" "$METRICS")

  # Serve a single request then loop
  printf '%s' "$RESPONSE" | nc -l -p "$PORT" -w 5 >/dev/null 2>&1 || true

done
