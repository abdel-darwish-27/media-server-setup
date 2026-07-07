# Home Media Server — Setup & Operations Manual

**Host:** Pop!_OS 24.04 LTS (Kernel 6.17) — 1TB NVMe at `/mnt/media`  
**VPN:** Private Internet Access (PIA)  
**Last updated:** 2026-07-08

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [VPN Performance Benchmarks](#vpn-performance-benchmarks)
3. [Prerequisites](#prerequisites)
4. [PIA Account Setup](#pia-account-setup)
5. [Directory Structure](#directory-structure)
6. [Docker & Compose Installation](#docker--compose-installation)
7. [Service Breakdown](#service-breakdown)
8. [Full docker-compose.yml](#full-docker-composeyml)
9. [Step-by-Step Setup](#step-by-step-setup)
10. [Accessing the Services](#accessing-the-services)
11. [Troubleshooting](#troubleshooting)
12. [Maintenance Commands](#maintenance-commands)
13. [Backup & Recovery](#backup--recovery)

---

## Architecture Overview

```
                    ┌─────────────────────────────────────────────┐
                    │              DOCKER HOST (Pop!_OS)           │
                    │              IP: 192.168.68.63               │
                    │                                             │
  Internet ────────►│  ┌──────────────────────────────────────┐   │
                    │  │    GLUETUN (PIA OpenVPN, Sydney)      │   │
                    │  │    DHCP-assigned IP: varies           │   │
                    │  │    Ports: 8989, 7878, 9696, 8191     │   │
                    │  │                                       │   │
                    │  │  ┌─────────────────────────────────┐  │   │
                    │  │  │ Sonarr  :8989  (TV shows)        │  │   │
                    │  │  │ Radarr  :7878  (Movies)          │  │   │
                    │  │  │ Prowlarr :9696  (Indexers)       │  │   │
                    │  │  │ Flaresolverr :8191 (CF bypass)   │  │   │
                    │  │  └─────────────────────────────────┘  │   │
                    │  └──────────────────────────────────────┘   │
                    │                                             │
                    │  ┌──────────────────────────────────────┐   │
                    │  │    QBITTORRENT (own PIA WireGuard)    │   │
                    │  │    Ports: 8080, 6881                  │   │
                    │  │    Built-in WireGuard tunnel          │   │
                    │  └──────────────────────────────────────┘   │
                    │                                             │
                    │  ┌──────────────────────────────────────┐   │
                    │  │    PLEX (host network, :32400)        │   │
                    │  │    No VPN — serves local media only   │   │
                    │  └──────────────────────────────────────┘   │
                    └─────────────────────────────────────────────┘
```

**Traffic flow:**
- **Sonarr/Radarr** → Search via Prowlarr (VPN'd) → Send magnet/torrent to qBittorrent → qBittorrent downloads via WireGuard → Sonarr/Radarr rename & move to library → Plex serves it
- All indexer traffic, search requests, and metadata queries from the `*arrs` go through Gluetun's OpenVPN tunnel
- Torrent traffic goes through qBittorrent's own WireGuard tunnel
- Plex serves locally on host network (no VPN needed)

**Why two VPN tunnels?**
- qBittorrent's WireGuard runs **inside** the qbittorrent container (built into the hotio image). Other containers can't share it.
- Gluetun is a dedicated VPN **gateway** container that multiple services can route through (`network_mode: "service:gluetun"`)
- PIA supports WireGuard in qBittorrent's hotio image but **not** in Gluetun (Gluetun's PIA WireGuard support is limited to: AirVPN, Mullvad, NordVPN, ProtonVPN, Surfshark, Windscribe). Therefore Gluetun uses PIA OpenVPN.

---

## VPN Performance Benchmarks

Speed tests run 2026-07-08 using `speedtest-cli` (Ookla) against the nearest Australian server.

### Results

| Test | Ping | Download | Upload | % of Line Rate |
|------|------|----------|--------|----------------|
| **Host (no VPN)** | 8 ms | **880 Mbps** | 51 Mbps | 100% |
| **qBittorrent (WireGuard)** | 33 ms | **859 Mbps** | 47 Mbps | **98%** |
| **Gluetun (OpenVPN)** | 10 ms | **538 Mbps** | 47 Mbps | **61%** |

### Interpretation

- **WireGuard runs at 98% of line rate** — barely any overhead. This is expected; WireGuard is known for minimal crypto overhead and runs in-kernel on Linux.
- **OpenVPN hits 538 Mbps** — ~60% of line rate. The encryption overhead (TLS handshake, user-space crypto processing) is the bottleneck. This is normal for OpenVPN on consumer hardware.
- Both are well above the ~60 Mbps that a single TCP connection from Australia to the US East Coast can achieve (bottleneck is latency/TCP window scaling, not the VPN).
- The 33 ms ping on WireGuard vs 10 ms on OpenVPN is routing-dependent (different PIA servers/peering). It does not measurably affect torrent download performance.

### Practical Impact

| Activity | WireGuard (859 Mbps) | OpenVPN (538 Mbps) |
|----------|---------------------|--------------------|
| 4K Blu-ray remux (~50 GB) | ~8 minutes | ~13 minutes |
| 1080p movie (~5 GB) | ~50 seconds | ~80 seconds |
| Indexer queries (KB-scale) | indistinguishable | indistinguishable |

**Bottom line:** The current split is ideal — WireGuard handles heavy torrent traffic at near-line speed, and OpenVPN's 538 Mbps is overkill for the lightweight *arr indexing/search queries it carries. No reason to change.

### How to Re-Test

```bash
# Host baseline
pip install speedtest-cli && speedtest-cli --simple

# qBittorrent (WireGuard)
docker exec qbittorrent python3 -c "import urllib.request; exec(urllib.request.urlopen('https://raw.githubusercontent.com/sivel/speedtest-cli/master/speedtest.py').read())" --simple 2>&1

# Gluetun (OpenVPN) — needs apk install first
docker exec gluetun-vpn apk add speedtest-cli
docker exec gluetun-vpn speedtest-cli --simple
```

---

## Prerequisites

### Hardware
- Any x86_64 PC with ≥4GB RAM, ≥100GB storage (media files need more)
- This setup runs on a Pop!_OS desktop with a 1TB NVMe drive

### Software
- Pop!_OS 24.04 LTS (or any Ubuntu/Debian-based distro)
- Docker Engine 29+
- Docker Compose v5+
- `git` and `gh` CLI for GitHub

### Accounts
- **Private Internet Access (PIA)** subscription — provides the VPN tunnel for all torrent/indexer traffic
  - Username format: `pXXXXXXX` (found in PIA account dashboard)
  - Password: your PIA account password
- GitHub account (optional — for version-controlling this setup)

---

## PIA Account Setup

1. Sign up at [privateinternetaccess.com](https://www.privateinternetaccess.com)
2. Note your username (usually `p` followed by 7 digits, e.g. `p9631274`)
3. Use your account password — **not** the PPTP/L2TP/SOCKS password from the control panel
4. Choose a region close to you. This setup uses `AU Sydney` for Gluetun and `aus` (3-letter code) for qBittorrent

---

## Directory Structure

```
/mnt/media/
├── docker-compose.yml          ← The entire stack defined here
├── README.md                   ← This manual
├── config/
│   ├── gluetun/                ← Gluetun VPN config & server list
│   ├── plex/                   ← Plex database & metadata
│   ├── prowlarr/               ← Prowlarr indexer config
│   ├── qbittorrent/            ← qBittorrent config & WireGuard keys
│   │   └── wireguard/          ← Auto-generated WG configs
│   ├── radarr/                 ← Radarr database & config
│   └── sonarr/                 ← Sonarr database & config
├── downloads/                  ← qBittorrent download directory
├── movies/                     ← Radarr library root
└── tv/                         ← Sonarr library root
```

Create the directories before first run:
```bash
mkdir -p /mnt/media/{config/{gluetun,plex,prowlarr,qbittorrent,radarr,sonarr},downloads,movies,tv}
```

---

## Docker & Compose Installation

On Pop!_OS / Ubuntu:

```bash
# Remove old versions
sudo apt-get remove docker docker-engine docker.io containerd runc 2>/dev/null

# Install prerequisites
sudo apt-get update
sudo apt-get install -y ca-certificates curl

# Add Docker's official GPG key
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Add your user to the docker group (logout/login after)
sudo usermod -aG docker $USER

# Verify
docker --version
docker compose version
```

---

## Service Breakdown

### Gluetun — VPN Gateway
| Field | Value |
|-------|-------|
| Image | `qmcgaw/gluetun:latest` |
| Protocol | OpenVPN (PIA) |
| Server | AU Sydney |
| CAP | `NET_ADMIN` (required for tunnel creation) |
| Exposed ports | 8989, 7878, 9696, 8191 |

**Why OpenVPN not WireGuard?** PIA's WireGuard implementation is not supported in Gluetun (only AirVPN, Mullvad, NordVPN, ProtonVPN, Surfshark, and Windscribe are). This may change in future Gluetun releases — to check, run: `docker run --rm qmcgaw/gluetun:latest -vpn_type wireguard -vpn_provider "private internet access"` and see if it errors.

**Key settings:**
- `FIREWALL_VPN_INPUT_PORTS` — ports Gluetun should allow IN from the local network (all the services behind it)
- `FIREWALL_OUTBOUND_SUBNETS` — local subnets the services behind Gluetun can reach (Docker bridge + LAN). Without this, the killswitch blocks all non-VPN traffic, including to qBittorrent.

### Sonarr — TV Shows
| Field | Value |
|-------|-------|
| Image | `linuxserver/sonarr:latest` |
| Web UI | `http://192.168.68.63:8989` |
| Network | `service:gluetun` (behind VPN) |
| Volumes | config, tv library, downloads |

### Radarr — Movies
| Field | Value |
|-------|-------|
| Image | `linuxserver/radarr:latest` |
| Web UI | `http://192.168.68.63:7878` |
| Network | `service:gluetun` (behind VPN) |
| Volumes | config, movies library, downloads |

### Prowlarr — Indexer Manager
| Field | Value |
|-------|-------|
| Image | `linuxserver/prowlarr:latest` |
| Web UI | `http://192.168.68.63:9696` |
| Network | `service:gluetun` (behind VPN) |
| Purpose | Manages torrent/usenet indexers, syncs them to Sonarr/Radarr |

### Flaresolverr — Cloudflare Bypass
| Field | Value |
|-------|-------|
| Image | `ghcr.io/flaresolverr/flaresolverr:latest` |
| Web UI | `http://192.168.68.63:8191` (no UI, just health check) |
| Network | `service:gluetun` (behind VPN) |
| Purpose | Solves Cloudflare challenges for indexers that use CF protection |

### qBittorrent — Download Client
| Field | Value |
|-------|-------|
| Image | `ghcr.io/hotio/qbittorrent:latest` |
| Web UI | `http://192.168.68.63:8080` |
| Protocol | built-in WireGuard (PIA) |
| CAP | `NET_ADMIN` |

### Plex — Media Server
| Field | Value |
|-------|-------|
| Image | `plexinc/pms-docker:latest` |
| Web UI | `http://192.168.68.63:32400/web` |
| Network | **host** (required for DLNA, remote access, discovery) |
| VPN | **None** (serves local media, no external content fetching) |

---

## Full docker-compose.yml

The canonical compose file lives at `/mnt/media/docker-compose.yml`. Contents:

```yaml
services:
  # ─── Gluetun VPN gateway (PIA OpenVPN) ───
  gluetun:
    image: qmcgaw/gluetun:latest
    container_name: gluetun-vpn
    cap_add:
      - NET_ADMIN
    environment:
      - VPN_SERVICE_PROVIDER=private internet access
      - VPN_TYPE=openvpn
      - SERVER_REGIONS=AU Sydney
      - OPENVPN_USER=pXXXXXXX           # ← Your PIA username
      - OPENVPN_PASSWORD=YOUR_PASSWORD  # ← Your PIA password
      - TZ=Australia/Sydney
      - FIREWALL_VPN_INPUT_PORTS=9696,8191,8989,7878
      - FIREWALL_OUTBOUND_SUBNETS=192.168.68.0/24,172.18.0.0/16
    ports:
      - "9696:9696"    # Prowlarr
      - "8191:8191"    # Flaresolverr
      - "8989:8989"    # Sonarr
      - "7878:7878"    # Radarr
    volumes:
      - /mnt/media/config/gluetun:/gluetun
    restart: unless-stopped

  # ─── Plex Media Server ───
  plex:
    image: plexinc/pms-docker:latest
    container_name: plex
    network_mode: host
    environment:
      - TZ=Australia/Sydney
      - PLEX_CLAIM=
      - ADVERTISE_IP=http://192.168.68.63:32400
    volumes:
      - /mnt/media/config/plex:/config
      - /mnt/media/tv:/data/tv
      - /mnt/media/movies:/data/movies
      - /mnt/media/downloads:/data/downloads
      - /tmp/plex-transcode:/transcode
    restart: unless-stopped

  # ─── Sonarr (TV Shows) ───
  sonarr:
    image: linuxserver/sonarr:latest
    container_name: sonarr
    network_mode: "service:gluetun"
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Australia/Sydney
    volumes:
      - /mnt/media/config/sonarr:/config
      - /mnt/media/tv:/tv
      - /mnt/media/downloads:/downloads
    depends_on:
      - gluetun
    restart: unless-stopped

  # ─── Radarr (Movies) ───
  radarr:
    image: linuxserver/radarr:latest
    container_name: radarr
    network_mode: "service:gluetun"
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Australia/Sydney
    volumes:
      - /mnt/media/config/radarr:/config
      - /mnt/media/movies:/movies
      - /mnt/media/downloads:/downloads
    depends_on:
      - gluetun
    restart: unless-stopped

  # ─── Prowlarr (Indexer Manager) ───
  prowlarr:
    image: linuxserver/prowlarr:latest
    container_name: prowlarr
    network_mode: "service:gluetun"
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Australia/Sydney
    volumes:
      - /mnt/media/config/prowlarr:/config
    depends_on:
      - gluetun
    restart: unless-stopped

  # ─── Flaresolverr (Cloudflare bypass) ───
  flaresolverr:
    image: ghcr.io/flaresolverr/flaresolverr:latest
    container_name: flaresolverr
    network_mode: "service:gluetun"
    environment:
      - TZ=Australia/Sydney
      - LOG_LEVEL=info
    depends_on:
      - gluetun
    restart: unless-stopped

  # ─── qBittorrent (built-in PIA WireGuard VPN) ───
  qbittorrent:
    image: ghcr.io/hotio/qbittorrent:latest
    container_name: qbittorrent
    cap_add:
      - NET_ADMIN
    environment:
      - PUID=1000
      - PGID=1000
      - UMASK=002
      - TZ=Australia/Sydney
      - WEBUI_PORTS=8080/tcp
      - VPN_ENABLED=true
      - VPN_CONF=wg
      - VPN_PROVIDER=pia
      - VPN_PIA_USER=pXXXXXXX             # ← Your PIA username
      - VPN_PIA_PASS=YOUR_PASSWORD        # ← Your PIA password
      - VPN_PIA_PREFERRED_REGION=aus
      - VPN_LAN_NETWORK=192.168.68.0/24
      - VPN_EXPOSE_PORTS_ON_LAN=8080/tcp
      - VPN_AUTO_PORT_FORWARD=true
      - VPN_PIA_PORT_FORWARD_PERSIST=false
    ports:
      - "8080:8080"
      - "6881:6881"
      - "6881:6881/udp"
    volumes:
      - /mnt/media/config/qbittorrent:/config
      - /mnt/media/downloads:/data/downloads
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
    restart: unless-stopped
```

---

## Step-by-Step Setup

### 1. Install Docker & Compose
See [Docker & Compose Installation](#docker--compose-installation) above.

### 2. Create directories
```bash
sudo mkdir -p /mnt/media/{config/{gluetun,plex,prowlarr,qbittorrent,radarr,sonarr},downloads,movies,tv}
sudo chown -R $USER:$USER /mnt/media
```

### 3. Create docker-compose.yml
Copy the compose file from this manual into `/mnt/media/docker-compose.yml`. Replace:
- `pXXXXXXX` → your PIA username
- `YOUR_PASSWORD` → your PIA password
- `192.168.68.0/24` → your LAN subnet (check with `ip route | grep link`)
- `TZ=Australia/Sydney` → your timezone
- `PUID=1000` / `PGID=1000` → your user/group IDs (check with `id`)

### 4. Start the VPN gateway first
```bash
cd /mnt/media
docker compose up -d gluetun
```

Wait ~20 seconds for the VPN to connect. Verify:
```bash
docker ps --format "{{.Names}} {{.Status}}"
# Should show: gluetun-vpn Up X seconds (healthy)
```

If it's stuck restarting, check logs:
```bash
docker logs gluetun-vpn --tail 20
```

### 5. Start everything else
```bash
cd /mnt/media
docker compose up -d
```

### 6. Verify all services
```bash
docker ps --format "table {{.Names}}\t{{.Status}}"
```

Expected output:
```
gluetun-vpn     Up (healthy)
sonarr          Up
radarr          Up
prowlarr        Up
flaresolverr    Up
qbittorrent     Up
plex            Up (healthy)
```

### 7. Verify VPN routing
```bash
# Check Gluetun's public IP (should be PIA, not your home IP)
docker exec gluetun-vpn wget -qO- ifconfig.me

# Check qBittorrent's public IP (should be PIA, different from Gluetun)
docker exec qbittorrent curl -s ifconfig.me
```

### 8. Configure the apps
See [Accessing the Services](#accessing-the-services) below.

---

## Accessing the Services

All web UIs are accessed from your local network at `http://192.168.68.63:PORT`:

| Service | URL | Default Login |
|---------|-----|---------------|
| Sonarr | `http://192.168.68.63:8989` | none by default (set one!) |
| Radarr | `http://192.168.68.63:7878` | none by default (set one!) |
| Prowlarr | `http://192.168.68.63:9696` | none by default (set one!) |
| qBittorrent | `http://192.168.68.63:8080` | `admin` / `adminadmin` (change immediately!) |
| Plex | `http://192.168.68.63:32400/web` | Plex account login |

### Initial Config Checklist

1. **qBittorrent** — Change default password in Settings → Web UI
2. **Prowlarr** — Add indexers (1337x, EZTV, The Pirate Bay, etc.), then Settings → Apps → add Sonarr & Radarr
3. **Sonarr** — Add a show, set quality profiles, set root folder to `/tv`
4. **Radarr** — Same, root folder `/movies`
5. **Sonarr/Radarr download clients** — Add qBittorrent at `http://qbittorrent:8080` with the admin credentials

---

## Troubleshooting

### Gluetun crashes: "default route not found"

**Symptom:** Container starts then immediately exits with `ERROR default route not found: in 4 route(s)`

**Likely causes & fixes:**

1. **Port conflict** — Another container is using a port that Gluetun needs to expose
   ```bash
   ss -tlnp | grep -E '9696|8191|8989|7878'
   # If any port is in use, stop the conflicting container first
   ```

2. **Devices / TUN module** — Ensure `/dev/net/tun` exists
   ```bash
   ls -la /dev/net/tun
   # Should show crw-rw-rw- 1 root root 10, 200 ...
   ```

3. **Wrong network order** — Always start Gluetun FIRST before services that depend on it
   ```bash
   docker compose up -d gluetun       # start VPN first
   sleep 20                            # wait for healthy
   docker compose up -d               # then everything else
   ```

### "Bind for 0.0.0.0:PORT failed: port is already allocated"

A container using the port is still running, or an old container wasn't properly removed:
```bash
docker ps -a --format "{{.Names}} {{.Status}} {{.Ports}}"
docker stop <container> && docker rm <container>
```

### PIA WireGuard in Gluetun not working

**PIA WireGuard is NOT supported by Gluetun** as of July 2026. The supported WireGuard providers are: AirVPN, Mullvad, NordVPN, ProtonVPN, Surfshark, Windscribe. PIA only works with OpenVPN in Gluetun.

### Services behind Gluetun can't reach qBittorrent

Check `FIREWALL_OUTBOUND_SUBNETS` includes the Docker bridge subnet:
```bash
# Find the Docker bridge subnet
docker network inspect media_default --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}'
# Usually 172.18.0.0/16 or 172.17.0.0/16
# Add it to FIREWALL_OUTBOUND_SUBNETS in docker-compose.yml and restart
```

### VPN is down and services are leaking traffic? (shouldn't happen)

Gluetun has a built-in killswitch. If the VPN drops, all containers behind Gluetun lose internet access entirely. This is by design.

Verify the killswitch works:
```bash
# Check public IP through Gluetun
docker exec gluetun-vpn wget -qO- ifconfig.me
# Should return a PIA IP, not your home IP
```

### Container stuck in "Created" status

The container was created but never started. Usually means `docker compose up` was interrupted:
```bash
docker compose rm -f <container>
docker compose up -d <container>
```

---

## Maintenance Commands

```bash
# View all running containers
docker ps --format "table {{.Names}}\t{{.Status}}"

# View logs for a specific service
docker logs gluetun-vpn --tail 50 -f
docker logs sonarr --tail 50

# Restart a single service
docker compose restart sonarr

# Update all images to latest and restart
docker compose pull
docker compose up -d

# Update a single image
docker compose pull gluetun
docker compose up -d gluetun

# Stop everything
docker compose down

# Start everything (Gluetun VPN must come up first)
docker compose up -d gluetun && sleep 20 && docker compose up -d

# Check VPN IPs (should both be PIA, not your home IP)
echo "Gluetun IP:" && docker exec gluetun-vpn wget -qO- ifconfig.me
echo "qBittorrent IP:" && docker exec qbittorrent curl -s ifconfig.me

# Check disk usage
df -h /mnt/media
# Check per-directory usage
du -sh /mnt/media/{config,downloads,movies,tv}
```

---

## Backup & Recovery

### What to backup
Everything important is in `/mnt/media/`:

| Path | What it contains | Priority |
|------|-----------------|----------|
| `docker-compose.yml` | The entire stack definition | **Critical** |
| `config/sonarr/` | Sonarr DB, shows list, settings | **High** |
| `config/radarr/` | Radarr DB, movies list, settings | **High** |
| `config/prowlarr/` | Indexer configs | Medium |
| `config/qbittorrent/` | Torrent list, settings | Medium |
| `config/plex/` | Plex database (can be large) | Medium |
| `config/gluetun/` | VPN server list (auto-regenerated) | Low |
| `downloads/` | In-progress torrents | Low |
| `movies/`, `tv/` | Media library | Re-obtainable |

### Backup script
```bash
#!/bin/bash
# Backup media server config to a tarball
BACKUP_DIR="/mnt/backups"
DATE=$(date +%Y%m%d_%H%M)
mkdir -p "$BACKUP_DIR"

tar -czf "$BACKUP_DIR/media-server-config_$DATE.tar.gz" \
  -C /mnt/media \
  docker-compose.yml \
  config/sonarr \
  config/radarr \
  config/prowlarr \
  config/qbittorrent \
  config/plex

echo "Backup saved to $BACKUP_DIR/media-server-config_$DATE.tar.gz"
```

### Restore
```bash
# Restore config from backup
cd /mnt/media
tar -xzf /mnt/backups/media-server-config_YYYYMMDD_HHMM.tar.gz
docker compose up -d
```

### Fresh rebuild from this manual
If the host machine dies and you need to rebuild from scratch:
1. Install OS (Pop!_OS or Ubuntu)
2. Install Docker & Compose (see above)
3. Create directories (see above)
4. Copy `docker-compose.yml` from this repo (replace PIA credentials)
5. `docker compose up -d gluetun && sleep 20 && docker compose up -d`
6. Restore config tarballs OR reconfigure apps through web UI
7. Re-add media files

---

## Network Reference

```
LAN subnet:     192.168.68.0/24
Host IP:        192.168.68.63
Docker bridge:  172.18.0.0/16 (auto-assigned, may vary)

PIA OpenVPN server: au-sydney.privacy.network (auto-selected by Gluetun)
PIA WireGuard server: aus### (auto-selected by qBittorrent)
```

---

## Changes Log

| Date | Change |
|------|--------|
| 2026-07-08 | Initial setup: qBittorrent + Sonarr + Radarr + Plex + Prowlarr + Flaresolverr |
| 2026-07-08 | Added Gluetun VPN gateway, routed Prowlarr + Flaresolverr through it |
| 2026-07-08 | Switched Gluetun to WireGuard then back to OpenVPN (PIA WG not supported in Gluetun) |
| 2026-07-08 | Moved Sonarr + Radarr behind Gluetun VPN — all *arr traffic now tunneled |
| 2026-07-08 | This manual created |
