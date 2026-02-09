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
mkdir -p "$PROJECT_DIR/arrdrive/data/sabnzbd/complete"
mkdir -p "$PROJECT_DIR/arrdrive/data/sabnzbd/incomplete"
mkdir -p "$PROJECT_DIR/arrdrive/data/Media/TV"
mkdir -p "$PROJECT_DIR/arrdrive/data/Media/Movies"

echo ">> Creating config directories..."
for svc in gluetun sonarr radarr prowlarr sabnzbd plex tautulli overseerr portainer prometheus grafana; do
  mkdir -p "$PROJECT_DIR/arrdrive/config/$svc"
done

# ── Set ownership ─────────────────────────────────────────────
REAL_UID=$(id -u "$REAL_USER")
REAL_GID=$(id -g "$REAL_USER")

chown -R "$REAL_USER:$REAL_USER" "$PROJECT_DIR/arrdrive/config" "$PROJECT_DIR/arrdrive/data"
echo "   Ownership set to $REAL_USER ($REAL_UID:$REAL_GID)"

# Grafana runs as uid 472 inside the container
chown -R 472:472 "$PROJECT_DIR/arrdrive/config/grafana"
echo "   Grafana config ownership set to 472:472"

# Prometheus runs as uid 65534 (nobody) inside the container
chown -R 65534:65534 "$PROJECT_DIR/arrdrive/config/prometheus"
echo "   Prometheus config ownership set to 65534:65534"

# ── Create .env from template ────────────────────────────────
if [[ ! -f "$PROJECT_DIR/.env" ]]; then
  echo ">> Creating .env from .env.example..."
  cp "$PROJECT_DIR/.env.example" "$PROJECT_DIR/.env"
  sed -i "s/^PUID=.*/PUID=$REAL_UID/" "$PROJECT_DIR/.env"
  sed -i "s/^PGID=.*/PGID=$REAL_GID/" "$PROJECT_DIR/.env"
  chown "$REAL_USER:$REAL_USER" "$PROJECT_DIR/.env"
  echo "   PUID=$REAL_UID, PGID=$REAL_GID injected into .env"
  echo "   >>> Edit .env to fill in WIREGUARD_PRIVATE_KEY, PLEX_CLAIM_TOKEN, etc."
else
  echo ">> .env already exists, skipping"
fi

# ── Add cron jobs ─────────────────────────────────────────────
BACKUP_CRON="0 3 * * * /usr/bin/bash $PROJECT_DIR/scripts/backup.sh >> /var/log/arrdocker-backup.log 2>&1"
VPN_CRON="*/5 * * * * /usr/bin/bash $PROJECT_DIR/scripts/vpn-healthcheck.sh >> /var/log/arrdocker-vpn.log 2>&1"
DEPLOY_CRON="* * * * * /usr/bin/bash $PROJECT_DIR/scripts/deploy.sh >> /var/log/arrdocker-deploy.log 2>&1"

if ! crontab -u "$REAL_USER" -l 2>/dev/null | grep -qF "arrdocker"; then
  echo ">> Adding cron jobs..."
  (crontab -u "$REAL_USER" -l 2>/dev/null || true; echo "$BACKUP_CRON"; echo "$VPN_CRON"; echo "$DEPLOY_CRON") | crontab -u "$REAL_USER" -
  echo "   Backup: daily at 3:00 AM"
  echo "   VPN health check: every 5 minutes"
  echo "   Auto-deploy: every minute"
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
echo "  3. Start the stacks:"
echo "     cd $PROJECT_DIR && docker compose up -d"
echo "     docker compose -f docker-compose.monitoring.yml up -d"
echo ""
