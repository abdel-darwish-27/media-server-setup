# Media Server Setup Reference

Last updated: 2026-07-07

## Hardware
- **Data drive:** Samsung 1TB NVMe (nvme1n1)
- **Mount point:** `/mnt/media` (ext4, auto-mounts via /etc/fstab)

## Directory Structure
```
/mnt/media/
├── tv/              # Sonarr library
├── movies/          # Radarr library
├── downloads/       # qBittorrent downloads
└── config/
    ├── plex/
    ├── sonarr/
    ├── radarr/
    ├── prowlarr/
    └── qbittorrent/
```

## Services (docker-compose at /mnt/media/docker-compose.yml)

| Service | Container | Port | URL | Notes |
|---------|-----------|------|-----|-------|
| Plex | plexinc/pms-docker | 32400 | http://192.168.68.63:32400/web | Host network mode |
| Sonarr | linuxserver/sonarr | 8989 | http://192.168.68.63:8989 | TV shows |
| Radarr | linuxserver/radarr | 7878 | http://192.168.68.63:7878 | Movies |
| Prowlarr | linuxserver/prowlarr | 9696 | http://192.168.68.63:9696 | Indexer manager |
| qBittorrent | ghcr.io/hotio/qbittorrent | 8080 | http://192.168.68.63:8080 | Torrent client |

## VPN
- **Provider:** Private Internet Access (PIA)
- **Protocol:** WireGuard
- **Region:** AU Sydney
- **qBittorrent IP:** 117.120.9.36 (PIA VPN tunnel)
- **All other services:** 115.70.50.12 (home IP — NOT through VPN)
- **Container:** hotio/qbittorrent with built-in WireGuard support
- **PIA forwarded port:** auto-assigned (currently 39552 — changes on reconnect without persistence)

## Credentials
- **PIA account:** <PIA_USERNAME> / <PIA_PASSWORD>
- **qBittorrent WebUI:** admin / <QBITTORRENT_PASSWORD>
- **PIA credentials file:** /mnt/media/config/pia-credentials.txt

## Port Forwarding (PIA)
- **Env var:** VPN_AUTO_PORT_FORWARD=true (not VPN_PORT_FORWARDING)
- Hotio image handles auto port request + binding via service-pia and service-forwarder
- Persistence disabled (VPN_PIA_PORT_FORWARD_PERSIST=false)
- Forwarded port written to /config/wireguard/forwarded_port inside container

## Docker Management
```bash
cd /mnt/media
# sudo required (unless user re-logs in for docker group)
echo '<SUDO_PASSWORD>' | sudo -S docker compose up -d          # Start all
echo '<SUDO_PASSWORD>' | sudo -S docker compose down           # Stop all
echo '<SUDO_PASSWORD>' | sudo -S docker compose logs -f        # Watch logs
echo '<SUDO_PASSWORD>' | sudo -S docker ps                     # Container status
```
