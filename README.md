# arrdocker

A complete Docker Compose media server stack for Ubuntu Server with VPN-routed downloads, Plex streaming, request management, and full monitoring via Prometheus and Grafana.

## Services

The stack is split into two independent compose files so monitoring and management stay online when you restart the main services.

### Main Stack (`docker-compose.yml`)

#### Media & Downloads (VPN-routed via Gluetun)

All download-related services share Gluetun's network namespace and route traffic through a ProtonVPN WireGuard tunnel.

| Service | Port | Description |
|---------|------|-------------|
| [Gluetun](https://github.com/qdm12/gluetun) | — | VPN gateway (ProtonVPN WireGuard) |
| [Sonarr](https://sonarr.tv) | 8989 | TV show management |
| [Radarr](https://radarr.video) | 7878 | Movie management |
| [Prowlarr](https://prowlarr.com) | 9696 | Indexer management |
| [SABnzbd](https://sabnzbd.org) | 8080 | Usenet download client |

#### Media Server & Requests

| Service | Port | Description |
|---------|------|-------------|
| [Plex](https://plex.tv) | 32400 | Media server with Intel Quick Sync hardware transcoding |
| [Tautulli](https://tautulli.com) | 8181 | Plex monitoring and analytics |
| [Overseerr](https://overseerr.dev) | 5055 | Media request management |

### Monitoring & Management Stack (`docker-compose.monitoring.yml`)

| Service | Port | Description |
|---------|------|-------------|
| [Portainer](https://portainer.io) | 9443 | Docker container management UI |
| [Prometheus](https://prometheus.io) | 9090 | Metrics collection (30-day retention) |
| [Grafana](https://grafana.com) | 3000 | Dashboards and visualization |
| [cAdvisor](https://github.com/google/cadvisor) | 8081 | Container resource metrics |
| [Node Exporter](https://github.com/prometheus/node_exporter) | 9100 | Host hardware/OS metrics |
| [Exportarr](https://github.com/onedr0p/exportarr) (x4) | 9707-9710 | Prometheus metrics for Sonarr, Radarr, Prowlarr, SABnzbd |
| VPN Exporter | 9101 | VPN health metrics for Prometheus |
| Tautulli Exporter | 9711 | Plex/Tautulli metrics for Prometheus |

## Network Architecture

```
             INTERNET
                |
           [ gluetun ] ── WireGuard tunnel ── ProtonVPN
           ports: 8989, 7878, 9696, 8080
                |
      shared network namespace:
      sonarr / radarr / prowlarr / sabnzbd
      (reach each other via localhost)
                |
           HOST PORTS
                |
      ┌─────────┼──────────┐
      overseerr  plex     grafana/prometheus/tautulli
      (host.docker.internal:port)
```

- **VPN-routed services** use `network_mode: "service:gluetun"` and communicate via `localhost`
- **Non-VPN services** reach VPN-routed services via `host.docker.internal:<port>`
- The monitoring stack communicates with main services via `host.docker.internal`, so the two compose projects are fully independent
- Gluetun includes a Docker health check — dependent services wait for a confirmed VPN connection before starting

## Prerequisites

- Ubuntu Server (20.04+)
- Docker and Docker Compose installed
- A ProtonVPN account with WireGuard credentials
- Intel CPU with Quick Sync (for Plex hardware transcoding — optional)

## Quick Start

```bash
# 1. Clone the repo
git clone https://github.com/your-username/arrdocker.git
cd arrdocker

# 2. Run the setup script
sudo bash scripts/setup.sh

# 3. Edit .env with your credentials
nano .env

# 4. Configure rclone for Proton Drive backups (optional)
rclone config

# 5. Start the main services
docker compose up -d

# 6. Start the monitoring & management stack
docker compose -f docker-compose.monitoring.yml up -d
```

## Configuration

### Environment Variables

Copy `.env.example` to `.env` and fill in your values:

| Variable | Description | Where to find it |
|----------|-------------|-----------------|
| `WIREGUARD_PRIVATE_KEY` | ProtonVPN WireGuard private key | ProtonVPN account > WireGuard config |
| `VPN_SERVER_COUNTRY` | VPN exit country (default: Netherlands) | — |
| `PLEX_CLAIM_TOKEN` | Plex server claim token | [plex.tv/claim](https://plex.tv/claim) |
| `SONARR_API_KEY` | Sonarr API key | Sonarr > Settings > General |
| `RADARR_API_KEY` | Radarr API key | Radarr > Settings > General |
| `PROWLARR_API_KEY` | Prowlarr API key | Prowlarr > Settings > General |
| `SABNZBD_API_KEY` | SABnzbd API key | SABnzbd > Config > General |
| `TAUTULLI_API_KEY` | Tautulli API key | Tautulli > Settings > Web Interface |
| `GRAFANA_ADMIN_USER` | Grafana admin username | — |
| `GRAFANA_ADMIN_PASSWORD` | Grafana admin password | — |

> **Note:** `PUID`, `PGID`, and `TZ` are auto-detected by `setup.sh`. API keys for the *arr apps and Tautulli are generated on first launch — start the stack, grab the keys from each app's settings, add them to `.env`, then restart the exporters:
>
> ```bash
> docker compose -f docker-compose.monitoring.yml restart exportarr-sonarr exportarr-radarr exportarr-prowlarr exportarr-sabnzbd tautulli-exporter
> ```

### Post-Deployment Service Setup

After starting both stacks, configure each service through its web UI:

**SABnzbd** (`localhost:8080`) — Add Usenet server credentials. Set complete folder to `/data/sabnzbd/complete`, incomplete to `/data/sabnzbd/incomplete`.

**Prowlarr** (`localhost:9696`) — Add indexers. Add Sonarr (`localhost:8989`) and Radarr (`localhost:7878`) as apps.

**Sonarr** (`localhost:8989`) — Set root folder to `/data/Media/TV`. Add SABnzbd as download client at `localhost:8080`.

**Radarr** (`localhost:7878`) — Set root folder to `/data/Media/Movies`. Add SABnzbd as download client at `localhost:8080`.

**Plex** (`localhost:32400/web`) — Add libraries: TV at `/data/Media/TV`, Movies at `/data/Media/Movies`. Enable hardware transcoding in Transcoder settings.

**Tautulli** (`localhost:8181`) — Complete setup wizard, point to Plex at `http://plex:32400`.

**Overseerr** (`localhost:5055`) — Connect to Plex at `http://host.docker.internal:32400`, Sonarr at `http://host.docker.internal:8989`, Radarr at `http://host.docker.internal:7878`.

**Grafana** (`localhost:3000`) — Add Prometheus data source at `http://prometheus:9090`. Dashboards are auto-provisioned in the "arrdocker" folder.

## Stack Management

The two compose projects are fully independent — you can restart one without affecting the other.

```bash
# ── Main services ────────────────────────────────────────────
docker compose up -d                          # Start
docker compose down                           # Stop
docker compose restart sonarr                 # Restart a single service
docker compose logs -f gluetun                # Follow logs

# ── Monitoring & management ──────────────────────────────────
docker compose -f docker-compose.monitoring.yml up -d       # Start
docker compose -f docker-compose.monitoring.yml down        # Stop
docker compose -f docker-compose.monitoring.yml logs -f grafana

# ── Rebuild custom exporters after code changes ──────────────
docker compose -f docker-compose.monitoring.yml up -d --build

# ── View all containers across both stacks ───────────────────
docker compose ps && docker compose -f docker-compose.monitoring.yml ps
```

## Grafana Dashboards

Six dashboards are auto-provisioned on startup:

| Dashboard | Description |
|-----------|-------------|
| **Host Health** | CPU, memory, disk, network, load, temperature, uptime |
| **Docker Containers** | Per-container CPU, memory, network, block I/O, status table |
| **VPN Health** | VPN up/down status, uptime, failure count, connectivity history |
| **Media Library** | Sonarr/Radarr series/movie counts, missing episodes, queue sizes, disk space |
| **Download Pipeline** | SABnzbd speed/queue/status, Prowlarr indexer stats, grab/query rates |
| **Plex (Tautulli)** | Active streams, transcode vs direct play, bandwidth (WAN/LAN), library size |

## Auto-Deploy

A cron job runs every minute (`scripts/deploy.sh`) that provides continuous deployment from GitHub without requiring inbound network access:

1. Runs `git fetch` to check for new commits on `origin/main`
2. Exits silently if already up to date (no log noise)
3. Pulls changes and determines which files were modified
4. Selectively restarts only the affected stack:
   - `docker-compose.yml` or `.env` changes → main stack restart
   - `docker-compose.monitoring.yml`, `exporters/`, `grafana/`, or `prometheus/` changes → monitoring stack restart
   - Scripts or docs only → no restart
5. Uses a lock file to prevent overlapping deploys

Logs to `/var/log/arrdocker-deploy.log`. See [Cron Jobs](#cron-jobs) for setup.

## VPN Health Check

A cron job runs every 5 minutes (`scripts/vpn-healthcheck.sh`) that:

1. Checks if the Gluetun container is running
2. Queries Gluetun's API to verify VPN connectivity
3. Restarts Gluetun if the tunnel is down
4. Logs results to `/var/log/arrdocker-vpn.log`

Additionally, the Docker health check on the Gluetun container ensures VPN-dependent services only start after a confirmed connection. See [Cron Jobs](#cron-jobs) for setup.

## Backups

A daily cron job at 3:00 AM (`scripts/backup.sh`) handles automated config backups:

- Stages all service configs (excluding caches, logs, transcodes)
- Includes `docker-compose.yml`, `docker-compose.monitoring.yml`, `.env`, and monitoring configs
- Creates a timestamped `.tar.gz` archive
- Uploads to Proton Drive via `rclone`
- Prunes remote backups older than 30 days
- Logs to `/var/log/arrdocker-backup.log`

**Setup:** Run `rclone config` to create a remote named `protondrive` pointing to your Proton Drive. See [Cron Jobs](#cron-jobs) for setup.

## Cron Jobs

The `setup.sh` script installs all three cron jobs automatically. To set them up manually instead, add any or all of the following to your crontab (`crontab -e`):

```bash
# Auto-deploy: pull git changes and restart affected stacks (every minute)
* * * * * /usr/bin/bash /opt/arrdocker/scripts/deploy.sh >> /var/log/arrdocker-deploy.log 2>&1

# VPN health check: restart gluetun if the tunnel drops (every 5 minutes)
*/5 * * * * /usr/bin/bash /opt/arrdocker/scripts/vpn-healthcheck.sh >> /var/log/arrdocker-vpn.log 2>&1

# Backup: archive configs and upload to Proton Drive (daily at 3:00 AM)
0 3 * * * /usr/bin/bash /opt/arrdocker/scripts/backup.sh >> /var/log/arrdocker-backup.log 2>&1
```

> **Note:** Replace `/opt/arrdocker` with your actual project path. All three are optional — pick whichever ones suit your setup.

| Job | Script | Schedule | Log |
|-----|--------|----------|-----|
| Auto-deploy | `scripts/deploy.sh` | Every minute | `/var/log/arrdocker-deploy.log` |
| VPN health check | `scripts/vpn-healthcheck.sh` | Every 5 minutes | `/var/log/arrdocker-vpn.log` |
| Backup | `scripts/backup.sh` | Daily at 3:00 AM | `/var/log/arrdocker-backup.log` |

## Directory Structure

```
arrdocker/
├── .env.example
├── .gitignore
├── docker-compose.yml              # Main services (8)
├── docker-compose.monitoring.yml   # Monitoring & management (12)
├── README.md
├── arrdrive/
│   ├── monitoring/
│   │   ├── prometheus.yml
│   │   ├── vpn-exporter/
│   │   │   ├── Dockerfile
│   │   │   └── exporter.sh
│   │   ├── tautulli-exporter/
│   │   │   ├── Dockerfile
│   │   │   └── exporter.sh
│   │   └── grafana/
│   │       ├── datasources.yml
│   │       ├── dashboards.yml
│   │       └── dashboards/
│   │           ├── host-health.json
│   │           ├── docker-containers.json
│   │           ├── vpn-health.json
│   │           ├── media-library.json
│   │           ├── download-pipeline.json
│   │           └── plex-tautulli.json
│   ├── config/                    # Persistent configs (git-ignored)
│   │   ├── gluetun/
│   │   ├── sonarr/
│   │   ├── radarr/
│   │   ├── prowlarr/
│   │   ├── sabnzbd/
│   │   ├── plex/
│   │   ├── tautulli/
│   │   ├── overseerr/
│   │   ├── portainer/
│   │   ├── prometheus/
│   │   └── grafana/
│   └── data/                      # Media & downloads (git-ignored)
│       ├── sabnzbd/
│       │   ├── complete/
│       │   └── incomplete/
│       └── Media/
│           ├── TV/
│           └── Movies/
├── scripts/
│   ├── setup.sh
│   ├── backup.sh
│   ├── deploy.sh
│   └── vpn-healthcheck.sh
```

## Verification

After starting both stacks:

```bash
# Check main services are running
docker compose ps

# Check monitoring services are running
docker compose -f docker-compose.monitoring.yml ps

# Verify VPN tunnel
docker exec gluetun wget -qO- ifconfig.me

# Check Prometheus targets
# Visit localhost:9090/targets — all targets should be UP

# Test cross-network connectivity
docker exec overseerr wget -qO- http://host.docker.internal:8989

# Run a backup manually
bash scripts/backup.sh
```

## Hardlinks

Sonarr and Radarr share the same `/data` mount, which allows hardlinks when moving completed downloads from `./arrdrive/data/sabnzbd/complete/` to `./arrdrive/data/Media/`. This avoids duplicating files and saves disk space.

## License

MIT
