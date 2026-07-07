# How to Download Movies on Request

This is the repeatable workflow for adding a movie to the media server.

## Prerequisites
- All Docker services running (`cd /mnt/media && docker compose up -d`)
- Flaresolverr + Prowlarr on host network (for Cloudflare bypass)
- qBittorrent WireGuard VPN active (for downloading)

## Step-by-Step

### 1. Search for the Movie on 1337x via Prowlarr
```bash
curl -s -H "X-Api-Key: <PROWLARR_API_KEY>" \
  "http://localhost:9696/api/v1/search?query=MOVIE_TITLE+2160p&indexerIds=1&limit=10" \
  --max-time 40 | python3 -c "
import json,sys
data = json.load(sys.stdin)
for r in sorted(data, key=lambda x: x.get('size',0), reverse=True)[:5]:
    sz = r.get('size',0)/(1024**3); seed = r.get('seeders',0)
    print(f'{sz:.0f}GB  {seed:3d}seeds  {r[\"title\"][:90]}')
"
```
> **Note:** The 40s timeout is required — Flaresolverr needs ~30s to bypass 1337x's Cloudflare protection.
> Indexer ID 1 = 1337x. For 4K content, Prowlarr searches via Flaresolverr → 1337x.

### 2. Download the .torrent via Prowlarr Proxy
The Prowlarr search response includes a `downloadUrl` field. Use it:
```bash
curl -s -L -o /tmp/movie.torrent "<DOWNLOAD_URL>" --max-time 60
```

### 3. Add to qBittorrent
```bash
# Auth via cookie session or API key (see below)
curl -s -X POST -b /tmp/qb_cookie.txt \
  "http://192.168.68.63:8080/api/v2/torrents/add" \
  -F "torrents=@/tmp/movie.torrent" \
  -F "savepath=/data/downloads" \
  -F "category=radarr"
```

### 4. Wait for Download
Monitor file size on disk:
```bash
watch -n 30 'ls -lh /mnt/media/downloads/'
```

### 5. Import into Plex
Once complete, trigger Plex library scan:
```bash
curl "http://localhost:32400/library/sections/1/refresh?X-Plex-Token=<PLEX_TOKEN>"
```

## Indexer Reference
| ID | Name | Flaresolverr | Notes |
|----|------|-------------|-------|
| 1 | 1337x | Yes (tag 1) | Primary source for 4K REMUX |
| 2 | YTS | No | Small encodes only (~8GB) |
| 3 | The Pirate Bay | Yes (tag 1) | apibay.org API, slow |
| 4 | LimeTorrents | Yes (tag 1) | Works |

## API Keys
- **Prowlarr:** `dcd53e0461db44d780c968bbcb193059` (config: `/mnt/media/config/prowlarr/config.xml`)
- **Radarr:** `a7bc3f91c1874d81a9f780c5953157aa` (config: `/mnt/media/config/radarr/config.xml`)
- **qBittorrent:** Uses random temp password or API key from config

## qBittorrent Auth Notes
- WireGuard VPN routes all traffic, including localhost — API auth can be flaky
- Temp password printed in logs: `docker logs qbittorrent | grep "temporary password"`
- API key stored in config: `docker exec qbittorrent grep APIKey /config/config/qBittorrent.conf`
- Auth subnet whitelist can bypass: add to `[Preferences]` in config
- Download files appear in `/mnt/media/downloads/` regardless of auth status
- Torrent files store in `/tmp/`; add via API or copy to qBittorrent watch folder

## Network Architecture
- **Prowlarr + Flaresolverr:** Host network — direct internet (bypasses Cloudflare)
- **qBittorrent:** Host network — own PIA WireGuard VPN (port 8080)
- **Radarr + Sonarr:** Behind Gluetun PIA OpenVPN (ports 7878, 8989)
- **Gluetun VPN:** Docker bridge, US East
- **Plex:** Host network (port 32400)
