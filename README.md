# arrdocker

A complete Docker Compose media server stack for Ubuntu Server with VPN-routed downloads, Plex streaming, request management, and full monitoring via Prometheus and Grafana.

## Services

### Media & Downloads (VPN-routed via Gluetun)

All download-related services share Gluetun's network namespace and route traffic through a ProtonVPN WireGuard tunnel.

| Service | Port | Description |
|---------|------|-------------|
| [Gluetun](https://github.com/qdm12/gluetun) | — | VPN gateway (ProtonVPN WireGuard) |
| [Sonarr](https://sonarr.tv) | 8989 | TV show management |
| [Radarr](https://radarr.video) | 7878 | Movie management |
| [Prowlarr](https://prowlarr.com) | 9696 | Indexer management |
| [SABnzbd](https://sabnzbd.org) | 8080 | Usenet download client |

### Media Server & Management

| Service | Port | Description |
|---------|------|-------------|
| [Plex](https://plex.tv) | 32400 | Media server with Intel Quick Sync hardware transcoding |
| [Tautulli](https://tautulli.com) | 8181 | Plex monitoring and analytics |
| [Overseerr](https://overseerr.dev) | 5055 | Media request management |
| [Portainer](https://portainer.io) | 9443 | Docker container management UI |

### Monitoring

| Service | Port | Description |
|---------|------|-------------|
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

# 5. Start the stack
docker compose up -d
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

> **Note:** `PUID`, `PGID`, and `TZ` are auto-detected by `setup.sh`. API keys for the *arr apps and Tautulli are generated on first launch — start the stack, grab the keys from each app's settings, add them to `.env`, then restart the exporters.

### Post-Deployment Service Setup

After `docker compose up -d`, configure each service through its web UI:

**SABnzbd** (`localhost:8080`) — Add Usenet server credentials. Set complete folder to `/data/sabnzbd/complete`, incomplete to `/data/sabnzbd/incomplete`.

**Prowlarr** (`localhost:9696`) — Add indexers. Add Sonarr (`localhost:8989`) and Radarr (`localhost:7878`) as apps.

**Sonarr** (`localhost:8989`) — Set root folder to `/data/Media/TV`. Add SABnzbd as download client at `localhost:8080`.

**Radarr** (`localhost:7878`) — Set root folder to `/data/Media/Movies`. Add SABnzbd as download client at `localhost:8080`.

**Plex** (`localhost:32400/web`) — Add libraries: TV at `/data/Media/TV`, Movies at `/data/Media/Movies`. Enable hardware transcoding in Transcoder settings.

**Tautulli** (`localhost:8181`) — Complete setup wizard, point to Plex at `http://plex:32400`.

**Overseerr** (`localhost:5055`) — Connect to Plex at `http://host.docker.internal:32400`, Sonarr at `http://host.docker.internal:8989`, Radarr at `http://host.docker.internal:7878`.

**Grafana** (`localhost:3000`) — Add Prometheus data source at `http://prometheus:9090`. Dashboards are auto-provisioned in the "arrdocker" folder.

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

## VPN Health Check

A cron job runs every 5 minutes (`scripts/vpn-healthcheck.sh`) that:

1. Checks if the Gluetun container is running
2. Queries Gluetun's API to verify VPN connectivity
3. Restarts Gluetun if the tunnel is down
4. Logs results to `/var/log/arrdocker-vpn.log`

Additionally, the Docker health check on the Gluetun container ensures VPN-dependent services only start after a confirmed connection.

## Backups

A daily cron job at 3:00 AM (`scripts/backup.sh`) handles automated config backups:

- Stages all service configs (excluding caches, logs, transcodes)
- Includes `docker-compose.yml`, `.env`, and monitoring configs
- Creates a timestamped `.tar.gz` archive
- Uploads to Proton Drive via `rclone`
- Prunes remote backups older than 30 days
- Logs to `/var/log/arrdocker-backup.log`

**Setup:** Run `rclone config` to create a remote named `protondrive` pointing to your Proton Drive.

## Directory Structure

```
arrdocker/
├── .env.example
├── .gitignore
├── docker-compose.yml
├── README.md
├── monitoring/
│   ├── prometheus.yml
│   ├── vpn-exporter/
│   │   ├── Dockerfile
│   │   └── exporter.sh
│   ├── tautulli-exporter/
│   │   ├── Dockerfile
│   │   └── exporter.sh
│   └── grafana/
│       ├── dashboards.yml
│       └── dashboards/
│           ├── host-health.json
│           ├── docker-containers.json
│           ├── vpn-health.json
│           ├── media-library.json
│           ├── download-pipeline.json
│           └── plex-tautulli.json
├── scripts/
│   ├── setup.sh
│   ├── backup.sh
│   └── vpn-healthcheck.sh
├── config/                    # Persistent configs (git-ignored)
│   ├── gluetun/
│   ├── sonarr/
│   ├── radarr/
│   ├── prowlarr/
│   ├── sabnzbd/
│   ├── plex/
│   ├── tautulli/
│   ├── overseerr/
│   ├── portainer/
│   ├── prometheus/
│   └── grafana/
└── data/                      # Media & downloads (git-ignored)
    ├── sabnzbd/
    │   ├── complete/
    │   └── incomplete/
    └── Media/
        ├── TV/
        └── Movies/
```

## Verification

After starting the stack:

```bash
# Check all containers are running
docker compose ps

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

Sonarr and Radarr share the same `/data` mount, which allows hardlinks when moving completed downloads from `./data/sabnzbd/complete/` to `./data/Media/`. This avoids duplicating files and saves disk space.

## License

MIT
