#!/bin/sh
# Lightweight Tautulli metrics exporter for Prometheus
# Polls Tautulli API and serves metrics on port 9711

TAUTULLI_URL="${TAUTULLI_URL:-http://host.docker.internal:8181}"
TAUTULLI_API_KEY="${TAUTULLI_API_KEY:-}"
PORT=9711

if [ -z "$TAUTULLI_API_KEY" ]; then
  echo "ERROR: TAUTULLI_API_KEY is not set"
  exit 1
fi

API="$TAUTULLI_URL/api/v2?apikey=$TAUTULLI_API_KEY"

while true; do
  # Fetch activity (current streams)
  ACTIVITY=$(wget -qO- --timeout=10 "$API&cmd=get_activity" 2>/dev/null || echo "")

  STREAM_COUNT=0
  TRANSCODE_COUNT=0
  DIRECT_PLAY_COUNT=0
  DIRECT_STREAM_COUNT=0
  WAN_BANDWIDTH=0
  LAN_BANDWIDTH=0
  TOTAL_BANDWIDTH=0

  if [ -n "$ACTIVITY" ]; then
    # Parse with sed/grep (no jq dependency)
    STREAM_COUNT=$(echo "$ACTIVITY" | sed -n 's/.*"stream_count"[[:space:]]*:[[:space:]]*"\{0,1\}\([0-9]*\)"\{0,1\}.*/\1/p' | head -1)
    STREAM_COUNT=${STREAM_COUNT:-0}

    TRANSCODE_COUNT=$(echo "$ACTIVITY" | sed -n 's/.*"stream_count_transcode"[[:space:]]*:[[:space:]]*"\{0,1\}\([0-9]*\)"\{0,1\}.*/\1/p' | head -1)
    TRANSCODE_COUNT=${TRANSCODE_COUNT:-0}

    DIRECT_PLAY_COUNT=$(echo "$ACTIVITY" | sed -n 's/.*"stream_count_direct_play"[[:space:]]*:[[:space:]]*"\{0,1\}\([0-9]*\)"\{0,1\}.*/\1/p' | head -1)
    DIRECT_PLAY_COUNT=${DIRECT_PLAY_COUNT:-0}

    DIRECT_STREAM_COUNT=$(echo "$ACTIVITY" | sed -n 's/.*"stream_count_direct_stream"[[:space:]]*:[[:space:]]*"\{0,1\}\([0-9]*\)"\{0,1\}.*/\1/p' | head -1)
    DIRECT_STREAM_COUNT=${DIRECT_STREAM_COUNT:-0}

    WAN_BANDWIDTH=$(echo "$ACTIVITY" | sed -n 's/.*"wan_bandwidth"[[:space:]]*:[[:space:]]*"\{0,1\}\([0-9]*\)"\{0,1\}.*/\1/p' | head -1)
    WAN_BANDWIDTH=${WAN_BANDWIDTH:-0}

    LAN_BANDWIDTH=$(echo "$ACTIVITY" | sed -n 's/.*"lan_bandwidth"[[:space:]]*:[[:space:]]*"\{0,1\}\([0-9]*\)"\{0,1\}.*/\1/p' | head -1)
    LAN_BANDWIDTH=${LAN_BANDWIDTH:-0}

    TOTAL_BANDWIDTH=$(echo "$ACTIVITY" | sed -n 's/.*"total_bandwidth"[[:space:]]*:[[:space:]]*"\{0,1\}\([0-9]*\)"\{0,1\}.*/\1/p' | head -1)
    TOTAL_BANDWIDTH=${TOTAL_BANDWIDTH:-0}
  fi

  # Fetch library stats
  LIBRARIES=$(wget -qO- --timeout=10 "$API&cmd=get_libraries" 2>/dev/null || echo "")

  MOVIE_COUNT=0
  SHOW_COUNT=0
  EPISODE_COUNT=0
  ARTIST_COUNT=0
  ALBUM_COUNT=0
  TRACK_COUNT=0

  if [ -n "$LIBRARIES" ]; then
    # Sum counts by section type
    # Movies
    MOVIE_COUNT=$(echo "$LIBRARIES" | grep -o '"section_type"[[:space:]]*:[[:space:]]*"movie"[^}]*"count"[[:space:]]*:[[:space:]]*"\{0,1\}[0-9]*"\{0,1\}' | grep -o '"count"[[:space:]]*:[[:space:]]*"\{0,1\}[0-9]*' | grep -o '[0-9]*$' | awk '{s+=$1} END {print s+0}')
    # Shows
    SHOW_COUNT=$(echo "$LIBRARIES" | grep -o '"section_type"[[:space:]]*:[[:space:]]*"show"[^}]*"count"[[:space:]]*:[[:space:]]*"\{0,1\}[0-9]*"\{0,1\}' | grep -o '"count"[[:space:]]*:[[:space:]]*"\{0,1\}[0-9]*' | grep -o '[0-9]*$' | awk '{s+=$1} END {print s+0}')
    # Child count for shows = episodes (approximate)
    EPISODE_COUNT=$(echo "$LIBRARIES" | grep -o '"section_type"[[:space:]]*:[[:space:]]*"show"[^}]*"child_count"[[:space:]]*:[[:space:]]*"\{0,1\}[0-9]*"\{0,1\}' | grep -o '"child_count"[[:space:]]*:[[:space:]]*"\{0,1\}[0-9]*' | grep -o '[0-9]*$' | awk '{s+=$1} END {print s+0}')
  fi

  METRICS=$(cat <<EOF
# HELP tautulli_active_streams Number of currently active Plex streams.
# TYPE tautulli_active_streams gauge
tautulli_active_streams $STREAM_COUNT
# HELP tautulli_transcode_streams Number of streams currently transcoding.
# TYPE tautulli_transcode_streams gauge
tautulli_transcode_streams $TRANSCODE_COUNT
# HELP tautulli_direct_play_streams Number of streams currently direct playing.
# TYPE tautulli_direct_play_streams gauge
tautulli_direct_play_streams $DIRECT_PLAY_COUNT
# HELP tautulli_direct_stream_streams Number of streams currently direct streaming.
# TYPE tautulli_direct_stream_streams gauge
tautulli_direct_stream_streams $DIRECT_STREAM_COUNT
# HELP tautulli_wan_bandwidth_kbps Current WAN bandwidth in kbps.
# TYPE tautulli_wan_bandwidth_kbps gauge
tautulli_wan_bandwidth_kbps $WAN_BANDWIDTH
# HELP tautulli_lan_bandwidth_kbps Current LAN bandwidth in kbps.
# TYPE tautulli_lan_bandwidth_kbps gauge
tautulli_lan_bandwidth_kbps $LAN_BANDWIDTH
# HELP tautulli_total_bandwidth_kbps Current total bandwidth in kbps.
# TYPE tautulli_total_bandwidth_kbps gauge
tautulli_total_bandwidth_kbps $TOTAL_BANDWIDTH
# HELP tautulli_library_movies Total number of movies in Plex libraries.
# TYPE tautulli_library_movies gauge
tautulli_library_movies $MOVIE_COUNT
# HELP tautulli_library_shows Total number of TV shows in Plex libraries.
# TYPE tautulli_library_shows gauge
tautulli_library_shows $SHOW_COUNT
# HELP tautulli_library_seasons Total number of seasons in Plex libraries.
# TYPE tautulli_library_seasons gauge
tautulli_library_seasons $EPISODE_COUNT
EOF
)

  CONTENT_LENGTH=$(printf '%s' "$METRICS" | wc -c)
  RESPONSE=$(printf "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" "$CONTENT_LENGTH" "$METRICS")

  printf '%s' "$RESPONSE" | nc -l -p "$PORT" -w 5 >/dev/null 2>&1 || true

done
