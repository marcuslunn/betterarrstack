#!/usr/bin/env bash
set -euo pipefail

# arrdocker - Automated config backup to Proton Drive via rclone

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
STAGING_DIR="/tmp/arrdocker-backup-$TIMESTAMP"
ARCHIVE_NAME="arrdocker-backup-$TIMESTAMP.tar.gz"
RCLONE_REMOTE="protondrive:arrdocker-backups"

echo "[$TIMESTAMP] Starting arrdocker backup..."

# ── Stage config directories ─────────────────────────────────
mkdir -p "$STAGING_DIR/config"

for svc in gluetun sonarr radarr prowlarr sabnzbd plex tautulli overseerr portainer prometheus grafana; do
  if [[ -d "$PROJECT_DIR/arrdrive/config/$svc" ]]; then
    rsync -a \
      --exclude='Cache' \
      --exclude='Logs' \
      --exclude='logs' \
      --exclude='Transcode' \
      --exclude='MediaCover' \
      "$PROJECT_DIR/arrdrive/config/$svc/" "$STAGING_DIR/config/$svc/"
  fi
done

# ── Copy compose, env, and monitoring config ──────────────────
cp "$PROJECT_DIR/docker-compose.yml" "$STAGING_DIR/"
[[ -f "$PROJECT_DIR/.env" ]] && cp "$PROJECT_DIR/.env" "$STAGING_DIR/"
cp -r "$PROJECT_DIR/arrdrive/monitoring" "$STAGING_DIR/"

# ── Create archive ────────────────────────────────────────────
echo "  Creating archive: $ARCHIVE_NAME"
tar -czf "/tmp/$ARCHIVE_NAME" -C "$STAGING_DIR" .

# ── Upload to Proton Drive ────────────────────────────────────
echo "  Uploading to $RCLONE_REMOTE..."
rclone copy "/tmp/$ARCHIVE_NAME" "$RCLONE_REMOTE/"

# ── Prune old backups (older than 30 days) ────────────────────
echo "  Pruning backups older than 30 days..."
rclone delete "$RCLONE_REMOTE/" --min-age 30d

# ── Cleanup ───────────────────────────────────────────────────
rm -rf "$STAGING_DIR" "/tmp/$ARCHIVE_NAME"

echo "[$TIMESTAMP] Backup complete: $ARCHIVE_NAME"
