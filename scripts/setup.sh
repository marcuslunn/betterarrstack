#!/usr/bin/env bash
set -euo pipefail

# arrdocker - Ubuntu Server initial setup
# Run with: sudo bash scripts/setup.sh

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root (sudo bash scripts/setup.sh)"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
REAL_USER="${SUDO_USER:-$USER}"

echo "=== arrdocker setup ==="
echo "Project directory: $PROJECT_DIR"
echo "Running as user: $REAL_USER"
echo ""

# ── Install packages ──────────────────────────────────────────
echo ">> Installing required packages..."
apt-get update -qq
apt-get install -y -qq curl wget git rsync rclone

# ── Install Docker ────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
  echo ">> Installing Docker..."
  curl -fsSL https://get.docker.com | sh
  usermod -aG docker "$REAL_USER"
  echo "   Added $REAL_USER to docker group (log out and back in to take effect)"
else
  echo ">> Docker already installed: $(docker --version)"
fi

# ── Create directory structure ────────────────────────────────
echo ">> Creating data directories..."
mkdir -p "$PROJECT_DIR/data/sabnzbd/complete"
mkdir -p "$PROJECT_DIR/data/sabnzbd/incomplete"
mkdir -p "$PROJECT_DIR/data/Media/TV"
mkdir -p "$PROJECT_DIR/data/Media/Movies"

echo ">> Creating config directories..."
for svc in gluetun sonarr radarr prowlarr sabnzbd plex tautulli overseerr portainer prometheus grafana; do
  mkdir -p "$PROJECT_DIR/config/$svc"
done

# ── Set ownership ─────────────────────────────────────────────
REAL_UID=$(id -u "$REAL_USER")
REAL_GID=$(id -g "$REAL_USER")

chown -R "$REAL_USER:$REAL_USER" "$PROJECT_DIR/config" "$PROJECT_DIR/data"
echo "   Ownership set to $REAL_USER ($REAL_UID:$REAL_GID)"

# ── Create .env from template ────────────────────────────────
if [[ ! -f "$PROJECT_DIR/.env" ]]; then
  echo ">> Creating .env from .env.example..."
  cp "$PROJECT_DIR/.env.example" "$PROJECT_DIR/.env"
  sed -i "s/^PUID=.*/PUID=$REAL_UID/" "$PROJECT_DIR/.env"
  sed -i "s/^PGID=.*/PGID=$REAL_GID/" "$PROJECT_DIR/.env"
  echo "   PUID=$REAL_UID, PGID=$REAL_GID injected into .env"
  echo "   >>> Edit .env to fill in WIREGUARD_PRIVATE_KEY, PLEX_CLAIM_TOKEN, etc."
else
  echo ">> .env already exists, skipping"
fi

# ── Add backup cron job ──────────────────────────────────────
BACKUP_CRON="0 3 * * * /usr/bin/bash $PROJECT_DIR/scripts/backup.sh >> /var/log/arrdocker-backup.log 2>&1"
VPN_CRON="*/5 * * * * /usr/bin/bash $PROJECT_DIR/scripts/vpn-healthcheck.sh >> /var/log/arrdocker-vpn.log 2>&1"

if ! crontab -u "$REAL_USER" -l 2>/dev/null | grep -qF "arrdocker"; then
  echo ">> Adding cron jobs..."
  (crontab -u "$REAL_USER" -l 2>/dev/null || true; echo "$BACKUP_CRON"; echo "$VPN_CRON") | crontab -u "$REAL_USER" -
  echo "   Backup: daily at 3:00 AM"
  echo "   VPN health check: every 5 minutes"
else
  echo ">> Cron jobs already exist, skipping"
fi

echo ""
echo "=== Setup complete ==="
echo ""
echo "Next steps:"
echo "  1. Edit .env with your credentials:"
echo "     nano $PROJECT_DIR/.env"
echo "  2. Configure rclone for Proton Drive:"
echo "     rclone config"
echo "  3. Start the stack:"
echo "     cd $PROJECT_DIR && docker compose up -d"
echo ""
