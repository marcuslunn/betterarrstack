# arrdocker - Docker Media Server Stack

## Overview

A complete Docker Compose stack on Ubuntu Server with media management, VPN-routed downloads, Plex streaming with Tautulli monitoring, request management, automated backups to Proton Drive, and full observability via Prometheus and Grafana with auto-provisioned dashboards.

## Directory Structure

```
arrdocker/
├── .env.example                  # Template with placeholder values
├── .gitignore
├── docker-compose.yml            # All services in one compose file
├── README.md
├── arrdrive/
│   ├── monitoring/
│   │   ├── prometheus.yml            # Prometheus scrape config
│   │   ├── vpn-exporter/
│   │   │   ├── Dockerfile
│   │   │   └── exporter.sh           # VPN health metrics for Prometheus
│   │   ├── tautulli-exporter/
│   │   │   ├── Dockerfile
│   │   │   └── exporter.sh           # Plex/Tautulli metrics for Prometheus
│   │   └── grafana/
│   │       ├── dashboards.yml        # Dashboard provisioning config
│   │       └── dashboards/
│   │           ├── host-health.json
│   │           ├── docker-containers.json
│   │           ├── vpn-health.json
│   │           ├── media-library.json
│   │           ├── download-pipeline.json
│   │           └── plex-tautulli.json
│   ├── config/                       # Persistent config volumes (git-ignored)
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
│   └── data/                         # Media & downloads (git-ignored)
│       ├── sabnzbd/
│       │   ├── complete/
│       │   └── incomplete/
│       └── Media/
│           ├── TV/
│           └── Movies/
├── scripts/
│   ├── setup.sh                  # Ubuntu Server initial setup
│   ├── backup.sh                 # Config backup to Proton Drive via rclone
│   └── vpn-healthcheck.sh        # Cron-based VPN monitor & auto-restart
```

## Network Architecture

### VPN-Routed Services (via `network_mode: "service:gluetun"`)
- Sonarr, Radarr, Prowlarr, SABnzbd all share gluetun's network namespace
- All ports exposed on the **gluetun** container: 8989, 7878, 9696, 8080
- These services reach each other via `localhost:<port>` (shared namespace)

### Non-VPN Services (default bridge network)
- Plex (:32400), Tautulli (:8181), Overseerr (:5055), Portainer (:9443), Grafana (:3000), Prometheus (:9090)

### Cross-Network Communication
- Overseerr uses `extra_hosts: ["host.docker.internal:host-gateway"]` to reach VPN-routed services via `host.docker.internal:<port>`
- Prometheus, Exportarr, and custom exporters use the same pattern
- cAdvisor reached via Docker DNS

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

### Gluetun Health Check
- Docker-level health check queries `http://localhost:9999/v1/publicip/ip` every 60s
- VPN-dependent services use `depends_on: gluetun: condition: service_healthy`
- Ensures VPN tunnel is confirmed before *arr services start

## Files

### 1. `.gitignore`
Ignore `.env`, `arrdrive/config/`, `arrdrive/data/`

### 2. `.env.example`
All environment variables with placeholders:
- `PUID`, `PGID` - system identity (detected by setup script)
- `TZ=America/New_York`
- `WIREGUARD_PRIVATE_KEY` - from ProtonVPN WireGuard config
- `VPN_SERVER_COUNTRY` - default `Netherlands`
- `PLEX_CLAIM_TOKEN` - from plex.tv/claim
- `SONARR_API_KEY`, `RADARR_API_KEY`, `PROWLARR_API_KEY`, `SABNZBD_API_KEY` - from each app's Settings > General after first launch
- `TAUTULLI_API_KEY` - from Tautulli > Settings > Web Interface > API Key
- `GRAFANA_ADMIN_USER`, `GRAFANA_ADMIN_PASSWORD`

No `MEDIA_ROOT` variable needed - paths are relative `./arrdrive/data` in compose file.

### 3. `arrdrive/monitoring/prometheus.yml`
Scrape targets (15s default interval, 30d retention):
- `localhost:9090` (self)
- `cadvisor:8080` (Docker DNS)
- `host.docker.internal:9100` (node-exporter)
- `vpn-exporter:9101` (30s interval)
- `exportarr-sonarr:9707`
- `exportarr-radarr:9708`
- `exportarr-prowlarr:9709`
- `exportarr-sabnzbd:9710`
- `tautulli-exporter:9711` (30s interval)

### 4. `docker-compose.yml`
20 services total:

| Service | Image | Network Mode | Ports (host) |
|---------|-------|-------------|--------------|
| gluetun | qmcgaw/gluetun | default + NET_ADMIN | 8989, 7878, 9696, 8080 |
| sonarr | linuxserver/sonarr | service:gluetun | (via gluetun) |
| radarr | linuxserver/radarr | service:gluetun | (via gluetun) |
| prowlarr | linuxserver/prowlarr | service:gluetun | (via gluetun) |
| sabnzbd | linuxserver/sabnzbd | service:gluetun | (via gluetun) |
| plex | linuxserver/plex | bridge | 32400 + discovery ports |
| tautulli | linuxserver/tautulli | bridge | 8181 |
| overseerr | linuxserver/overseerr | bridge + extra_hosts | 5055 |
| portainer | portainer-ce:lts | bridge | 9443, 8000 |
| prometheus | prom/prometheus | bridge + extra_hosts | 9090 |
| cadvisor | google/cadvisor | bridge (privileged) | 8081 |
| node-exporter | prom/node-exporter | bridge | 9100 |
| exportarr-sonarr | onedr0p/exportarr | bridge + extra_hosts | 9707 |
| exportarr-radarr | onedr0p/exportarr | bridge + extra_hosts | 9708 |
| exportarr-prowlarr | onedr0p/exportarr | bridge + extra_hosts | 9709 |
| exportarr-sabnzbd | onedr0p/exportarr | bridge + extra_hosts | 9710 |
| tautulli-exporter | custom (Alpine) | bridge + extra_hosts | 9711 |
| vpn-exporter | custom (Alpine) | bridge + extra_hosts | 9101 |
| grafana | grafana/grafana-enterprise | bridge | 3000 |

Key details:
- VPN-routed services use `depends_on: gluetun: condition: service_healthy`
- Gluetun has a Docker health check against its API (`localhost:9999/v1/publicip/ip`)
- Plex gets Intel Quick Sync via `devices: ["/dev/dri:/dev/dri"]`
- cAdvisor remapped to 8081 to avoid SABnzbd conflict on 8080
- Exportarr sidecars reach *arr services via `host.docker.internal`
- Grafana auto-provisions dashboards from `arrdrive/monitoring/grafana/dashboards/`

Volume mounts:
- Sonarr: `./arrdrive/config/sonarr:/config`, `./arrdrive/data:/data`
- Radarr: `./arrdrive/config/radarr:/config`, `./arrdrive/data:/data`
- SABnzbd: `./arrdrive/config/sabnzbd:/config`, `./arrdrive/data/sabnzbd:/data/sabnzbd`
- Plex: `./arrdrive/config/plex:/config`, `./arrdrive/data/Media:/data/Media:ro`
- Prowlarr: `./arrdrive/config/prowlarr:/config` (no media access needed)
- Tautulli: `./arrdrive/config/tautulli:/config`

The shared `/data` mount for Sonarr/Radarr allows hardlinks when moving completed downloads from `./arrdrive/data/sabnzbd/complete/` to `./arrdrive/data/Media/`. This avoids copying files and saves disk space.

### 5. `arrdrive/monitoring/vpn-exporter/`
Custom lightweight Alpine container that:
- Polls Gluetun's API (`localhost:9999/v1/publicip/ip`) for VPN status
- Checks container uptime via Docker socket
- Serves Prometheus metrics on port 9101:
  - `vpn_status` (gauge: 1=up, 0=down)
  - `vpn_connection_failures_total` (counter)
  - `vpn_uptime_seconds` (gauge)

### 6. `arrdrive/monitoring/tautulli-exporter/`
Custom lightweight Alpine container that:
- Polls Tautulli's API for activity, bandwidth, and library stats
- Serves Prometheus metrics on port 9711:
  - `tautulli_active_streams`, `tautulli_transcode_streams`, `tautulli_direct_play_streams`, `tautulli_direct_stream_streams`
  - `tautulli_wan_bandwidth_kbps`, `tautulli_lan_bandwidth_kbps`, `tautulli_total_bandwidth_kbps`
  - `tautulli_library_movies`, `tautulli_library_shows`, `tautulli_library_seasons`

### 7. `arrdrive/monitoring/grafana/dashboards.yml`
Provisioning config that auto-loads all JSON dashboards from `arrdrive/monitoring/grafana/dashboards/` into an "arrdocker" folder in Grafana.

### 8. Grafana Dashboards (6 total, auto-provisioned)

**Host Health** (`host-health.json`):
- CPU gauge + usage over time (user/system/iowait)
- Memory gauge + stacked breakdown (used/buffers/cached/available)
- Disk usage gauge + disk space table by mount
- Disk I/O (read/write per device)
- Network traffic (receive/transmit, excluding virtual interfaces)
- System load (1m/5m/15m), uptime, CPU temperature

**Docker Containers** (`docker-containers.json`):
- Running container count, total CPU/memory/network stats
- Per-container CPU, memory, network RX/TX, block I/O time series
- Container status table with CPU %, memory, memory limit

**VPN Health** (`vpn-health.json`):
- VPN status (UP/DOWN), uptime, failure count stats
- VPN status over time (timeline graph)
- Failure rate per hour (bar chart)

**Media Library** (`media-library.json`):
- Sonarr: series count, episode count, missing episodes, monitored/unmonitored pie, queue, disk space, trends
- Radarr: movie count, downloaded, missing, monitored/unmonitored pie, queue, disk space, trends

**Download Pipeline** (`download-pipeline.json`):
- SABnzbd: download speed, queue size, remaining data, pause status, total downloaded, speed/queue over time
- Prowlarr: indexer count, enabled count, grabs, queries, failures, grabs/queries per hour

**Plex / Tautulli** (`plex-tautulli.json`):
- Active streams, transcode/direct play/direct stream counts + pie chart
- Bandwidth stats (total/WAN/LAN) + over time
- Stream types over time (stacked area)
- Library stats (movies, shows, seasons) + growth over time

### 9. `scripts/setup.sh`
Ubuntu Server first-run script (run with sudo):
1. Install packages: curl, wget, git, rsync, rclone
2. Docker is presumed already installed
3. Create `./arrdrive/data` directories (`sabnzbd/complete`, `sabnzbd/incomplete`, `Media/TV`, `Media/Movies`)
4. Create `./arrdrive/config` directories for all 11 services
5. Set ownership to the invoking user
6. Copy `.env.example` to `.env`, inject detected PUID/PGID, chown to invoking user
7. Add cron jobs:
   - Daily backup at 3:00 AM
   - VPN health check every 5 minutes

### 10. `scripts/vpn-healthcheck.sh`
Cron-based VPN monitor (every 5 minutes):
1. Checks if gluetun container is running, starts it if not
2. Queries Gluetun API for VPN public IP
3. If no IP returned, restarts gluetun and re-checks after 20s
4. Logs to `/var/log/arrdocker-vpn.log`

### 11. `scripts/backup.sh`
Automated config backup:
- Uses rsync to stage config dirs (excludes Cache, Logs, Transcode, MediaCover)
- Also copies `docker-compose.yml`, `.env`, `arrdrive/monitoring/`
- Creates timestamped `.tar.gz` archive
- Uploads to Proton Drive via `rclone copy`
- Prunes remote backups older than 30 days
- Logs to `/var/log/arrdocker-backup.log`

### 12. `README.md`
Full project documentation for GitHub covering all services, architecture, setup, configuration, dashboards, and verification steps.

## Post-Deployment Configuration (manual, in web UIs)

### SABnzbd (localhost:8080)
- Add Usenet server credentials
- Complete folder = `/data/sabnzbd/complete`, Incomplete = `/data/sabnzbd/incomplete`

### Prowlarr (localhost:9696)
- Add indexers
- Add Sonarr app: `localhost:8989`, Add Radarr app: `localhost:7878`

### Sonarr (localhost:8989)
- Root folder: `/data/Media/TV`
- Download client: SABnzbd at `localhost:8080`

### Radarr (localhost:7878)
- Root folder: `/data/Media/Movies`
- Download client: SABnzbd at `localhost:8080`

### Plex (localhost:32400/web)
- Add libraries: TV = `/data/Media/TV`, Movies = `/data/Media/Movies`
- Enable hardware transcoding in Transcoder settings

### Tautulli (localhost:8181)
- Complete setup wizard, point to Plex at `http://plex:32400`
- Grab API key from Settings > Web Interface, add to `.env`
- Restart tautulli-exporter: `docker compose restart tautulli-exporter`

### Overseerr (localhost:5055)
- Plex: `http://host.docker.internal:32400`
- Sonarr: `http://host.docker.internal:8989`
- Radarr: `http://host.docker.internal:7878`

### Grafana (localhost:3000)
- Add data source: Prometheus at `http://prometheus:9090`
- Dashboards are auto-provisioned in the "arrdocker" folder (6 dashboards)

### API Keys (after first launch)
- Grab API keys from Sonarr, Radarr, Prowlarr, SABnzbd, and Tautulli settings
- Add to `.env` file
- Restart exporters: `docker compose restart exportarr-sonarr exportarr-radarr exportarr-prowlarr exportarr-sabnzbd tautulli-exporter`

## Verification Plan

1. **Syntax check**: `docker compose config` to validate compose file
2. **VPN verify**: `docker exec gluetun wget -qO- ifconfig.me` confirms VPN IP
3. **Service health**: `docker compose ps` shows all containers healthy
4. **Cross-network**: `docker exec overseerr wget -qO- http://host.docker.internal:8989` confirms Overseerr can reach Sonarr
5. **Monitoring**: Visit Prometheus targets page (localhost:9090/targets) - all 9 targets should be UP
6. **Dashboards**: Visit Grafana (localhost:3000) - 6 dashboards in "arrdocker" folder
7. **Backup dry-run**: Run `scripts/backup.sh` and verify archive on Proton Drive
8. **VPN health check**: Run `scripts/vpn-healthcheck.sh` and check `/var/log/arrdocker-vpn.log`
