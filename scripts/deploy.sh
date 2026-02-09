#!/usr/bin/env bash
set -euo pipefail

# arrdocker - Auto-deploy on git changes (runs via cron)
# Pulls latest changes from origin/main and restarts affected stacks.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BRANCH="main"
LOCKFILE="/tmp/arrdocker-deploy.lock"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# ── Prevent overlapping runs ─────────────────────────────────
if [[ -f "$LOCKFILE" ]]; then
  LOCK_PID=$(cat "$LOCKFILE" 2>/dev/null || true)
  if kill -0 "$LOCK_PID" 2>/dev/null; then
    log "Deploy already running (PID $LOCK_PID), skipping."
    exit 0
  fi
  rm -f "$LOCKFILE"
fi
echo $$ > "$LOCKFILE"
trap 'rm -f "$LOCKFILE"' EXIT

# ── Check for remote changes ─────────────────────────────────
cd "$PROJECT_DIR"

git fetch origin "$BRANCH" --quiet

LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse "origin/$BRANCH")

if [[ "$LOCAL" == "$REMOTE" ]]; then
  exit 0
fi

log "Changes detected: ${LOCAL:0:7} -> ${REMOTE:0:7}"

# ── Pull changes ─────────────────────────────────────────────
git pull origin "$BRANCH" --quiet
log "Pulled latest from origin/$BRANCH"

# ── Determine what changed ───────────────────────────────────
CHANGED=$(git diff --name-only "$LOCAL" "$REMOTE")
log "Changed files:"
echo "$CHANGED" | sed 's/^/  /'

RESTART_MAIN=false
RESTART_MONITORING=false

while IFS= read -r file; do
  case "$file" in
    docker-compose.yml|.env|.env.example)
      RESTART_MAIN=true
      ;;
    docker-compose.monitoring.yml)
      RESTART_MONITORING=true
      ;;
    exporters/*|monitoring/*)
      RESTART_MONITORING=true
      ;;
    grafana/*|prometheus/*)
      RESTART_MONITORING=true
      ;;
    *)
      # Scripts or docs changed - no restart needed
      ;;
  esac
done <<< "$CHANGED"

# ── Restart affected stacks ──────────────────────────────────
if [[ "$RESTART_MAIN" == true ]]; then
  log "Restarting main stack..."
  docker compose -f "$PROJECT_DIR/docker-compose.yml" up -d --remove-orphans
  log "Main stack restarted."
fi

if [[ "$RESTART_MONITORING" == true ]]; then
  log "Restarting monitoring stack..."
  docker compose -f "$PROJECT_DIR/docker-compose.monitoring.yml" up -d --remove-orphans
  log "Monitoring stack restarted."
fi

if [[ "$RESTART_MAIN" == false && "$RESTART_MONITORING" == false ]]; then
  log "No stack-affecting changes. Skipping restart."
fi

log "Deploy complete."
