#!/bin/sh
# Dynamic Docker service health exporter for Prometheus
# Discovers running containers with exposed HTTP ports via Docker socket,
# probes each one, and serves health metrics on port 9112.

PORT=9112
CHECK_INTERVAL=30
DOCKER_SOCKET="/var/run/docker.sock"

# Known HTTP ports to probe (container_name -> port mapping is auto-discovered)
# Some services need a specific path to return a healthy response
get_health_path() {
  case "$1" in
    sonarr)     echo "/ping" ;;
    radarr)     echo "/ping" ;;
    prowlarr)   echo "/ping" ;;
    sabnzbd)    echo "/sabnzbd/api?mode=version" ;;
    plex)       echo "/identity" ;;
    tautulli)   echo "/status" ;;
    overseerr)  echo "/api/v1/status" ;;
    portainer)  echo "/" ;;
    grafana)    echo "/api/health" ;;
    prometheus) echo "/-/healthy" ;;
    *)          echo "/" ;;
  esac
}

# Ports that are likely HTTP services (common web UI / API ports)
is_http_port() {
  port="$1"
  case "$port" in
    80|443|3000|5055|7878|8080|8081|8181|8384|8443|8686|8787|8888|8989|9090|9091|9117|9443|9696|9999|32400)
      return 0 ;;
    *)
      # Accept any port in typical web ranges
      if [ "$port" -ge 3000 ] 2>/dev/null && [ "$port" -le 9999 ] 2>/dev/null; then
        return 0
      fi
      if [ "$port" -ge 32000 ] 2>/dev/null && [ "$port" -le 33000 ] 2>/dev/null; then
        return 0
      fi
      return 1 ;;
  esac
}

# Query Docker API via socket to list running containers
get_containers() {
  # Use wget to query the Docker Engine API through the unix socket
  # Returns JSON array of running containers
  wget -qO- --timeout=5 "http://localhost/containers/json" 2>/dev/null \
    || echo "[]"
}

# Extract container info using sed/grep (no jq dependency, matching project style)
# Parses the Docker API JSON to get container names and their published port mappings
parse_containers() {
  raw="$1"

  # Process each container object - extract Name and port bindings
  # Docker API returns Names as ["/containername"]
  # and Ports as array of objects with PrivatePort, PublicPort, Type

  # Split into individual container blocks by looking for "Id" field boundaries
  echo "$raw" | sed 's/},{"Id"/}\n{"Id"/g' | while IFS= read -r container; do
    # Extract container name (remove leading /)
    name=$(echo "$container" | sed 's/.*"Names":\["\///' | sed 's/".*//')

    # Skip monitoring infrastructure containers (they're not user services)
    case "$name" in
      health-exporter|cadvisor|node-exporter|exportarr-*|vpn-exporter|tautulli-exporter)
        continue ;;
    esac

    # Extract all PrivatePort values from the Ports array
    # Docker API format: "PrivatePort":8989,"PublicPort":8989,"Type":"tcp"
    ports=$(echo "$container" | grep -oE '"PrivatePort":[0-9]+' | sed 's/"PrivatePort"://' | sort -u)

    for port in $ports; do
      if is_http_port "$port"; then
        echo "${name}:${port}"
      fi
    done
  done | sort -u
}

# Determine the correct address to reach a container
# All services are reached via host-published ports since health-exporter
# runs in the monitoring compose project, separate from main services.
get_probe_address() {
  name="$1"
  port="$2"
  echo "host.docker.internal:${port}"
}

# Use HTTPS for known HTTPS-only services
get_protocol() {
  name="$1"
  port="$2"
  case "$port" in
    443|8443|9443) echo "https" ;;
    *)             echo "http" ;;
  esac
}

# Main loop: discover, probe, serve
while true; do
  # Discover containers via Docker socket (using socat to bridge unix socket to TCP)
  CONTAINERS_JSON=$(echo -e "GET /containers/json HTTP/1.0\r\nHost: localhost\r\n\r\n" \
    | socat - UNIX-CONNECT:"$DOCKER_SOCKET" 2>/dev/null \
    | sed '1,/^\r$/d')

  SERVICES=$(parse_containers "$CONTAINERS_JSON")

  # Build metrics
  METRICS="# HELP service_up Whether the service HTTP endpoint is reachable (1=up, 0=down).
# TYPE service_up gauge
# HELP service_response_ms HTTP response time in milliseconds.
# TYPE service_response_ms gauge
# HELP service_http_status HTTP status code returned by the service.
# TYPE service_http_status gauge
# HELP service_health_checks_total Total number of health checks performed.
# TYPE service_health_checks_total counter"

  CHECKS_FILE="/tmp/health_checks_total"

  for svc in $SERVICES; do
    name=$(echo "$svc" | cut -d: -f1)
    port=$(echo "$svc" | cut -d: -f2)
    path=$(get_health_path "$name")
    address=$(get_probe_address "$name" "$port")
    protocol=$(get_protocol "$name" "$port")

    # Increment check counter for this service
    count_file="/tmp/health_count_${name}_${port}"
    count=$(cat "$count_file" 2>/dev/null || echo "0")
    count=$((count + 1))
    echo "$count" > "$count_file"

    # Probe the service with timing
    start_ms=$(date +%s%N 2>/dev/null | cut -c1-13)
    if [ "$protocol" = "https" ]; then
      response=$(wget -qO/dev/null -S --no-check-certificate --timeout=5 \
        "${protocol}://${address}${path}" 2>&1 || echo "HTTP/1.1 000")
    else
      response=$(wget -qO/dev/null -S --timeout=5 \
        "${protocol}://${address}${path}" 2>&1 || echo "HTTP/1.1 000")
    fi
    end_ms=$(date +%s%N 2>/dev/null | cut -c1-13)

    # Calculate response time
    if [ -n "$start_ms" ] && [ -n "$end_ms" ] && [ "$end_ms" -gt "$start_ms" ] 2>/dev/null; then
      response_ms=$((end_ms - start_ms))
    else
      response_ms=0
    fi

    # Extract HTTP status code
    http_status=$(echo "$response" | grep -oE 'HTTP/[0-9.]+ [0-9]+' | tail -1 | awk '{print $2}')
    http_status=${http_status:-0}

    # Determine if service is up (any 2xx or 3xx response = healthy)
    if [ "$http_status" -ge 200 ] 2>/dev/null && [ "$http_status" -lt 400 ] 2>/dev/null; then
      up=1
    else
      up=0
    fi

    METRICS="${METRICS}
service_up{service=\"${name}\",port=\"${port}\"} ${up}
service_response_ms{service=\"${name}\",port=\"${port}\"} ${response_ms}
service_http_status{service=\"${name}\",port=\"${port}\"} ${http_status}
service_health_checks_total{service=\"${name}\",port=\"${port}\"} ${count}"
  done

  # Serve metrics via netcat
  CONTENT_LENGTH=$(printf '%s' "$METRICS" | wc -c)
  RESPONSE=$(printf "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" "$CONTENT_LENGTH" "$METRICS")

  printf '%s' "$RESPONSE" | nc -l -p "$PORT" -w 5 >/dev/null 2>&1 || true

done
