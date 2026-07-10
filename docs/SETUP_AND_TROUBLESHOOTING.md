# Media Server Setup & Troubleshooting

Last updated: 2026-07-10

---

## Architecture

All services run in Docker on a single host with a 938G NVMe drive at `/mnt/media`.

```
/mnt/media/
├── config/        # Docker configs (Sonarr, qBittorrent, Plex, etc.)
├── downloads/     # qBittorrent download directory
├── movies/        # Radarr/Plex movie library
├── tv/            # Sonarr/Plex TV library
└── docker-compose.yml
```

---

## Volume Mounts (Critical for Hardlinks)

**The key insight**: Sonarr and qBittorrent must share a **single Docker volume mount** for hardlinks to work. Separate bind mounts to the same physical disk appear as different devices inside Docker, which breaks the kernel's ability to hardlink between them.

### Correct configuration (as of 2026-07-09):

**Sonarr:**
```yaml
volumes:
  - /mnt/media/config/sonarr:/config
  - /mnt/media:/media          # ← single mount, NOT separate /tv + /downloads
```

**qBittorrent:**
```yaml
volumes:
  - /mnt/media/config/qbittorrent:/config
  - /mnt/media:/media          # ← same single mount
```

Inside both containers:
- TV shows → `/media/tv/`
- Downloads → `/media/downloads/`
- Movies → `/media/movies/`

Because both containers share the same `/media` mount, Sonarr can create hardlinks. The file appears in both `/media/downloads/` (seeding) and `/media/tv/` (Plex library), but both entries point to the same data on disk. Deleting one does not free space until the other is also deleted.

### Sonarr Path Config
- **Root folder**: `/media/tv/`
- **Download client remote path mapping**: `/media/downloads/` → `/media/downloads/`

### What NOT to do (old broke config):
```yaml
# ❌ This breaks hardlinks:
volumes:
  - /mnt/media/tv:/data/tv
  - /mnt/media/downloads:/downloads
  # These are separate Docker bind mounts → no hardlinks possible
```

---

## qBittorrent Seeding Limits

Configured via API (set 2026-07-09, updated 2026-07-10):

| Setting | Value | Meaning |
|---------|-------|---------|
| `max_ratio_enabled` | `true` | Enable ratio limit |
| `max_ratio` | `2.0` | Stop seeding at 200% ratio |
| `max_seeding_time_enabled` | `true` | Enable time limit |
| `max_seeding_time` | `168` | Stop seeding after 168 hours (7 days) |
| `max_ratio_act` | `0` | **Pause** torrent when limit hit (0=pause, 1=remove, 2=superseed) |

> **Note:** `max_ratio_act` was changed from `1` (remove) to `0` (pause) on 2026-07-10. Sonarr warns that removing completed downloads before it can import them causes missing files. With `0`, torrents pause at the limit and Sonarr imports at its own pace. Manually remove paused torrents once verified in Plex.

**Result**: Torrents pause at ratio 2.0 OR 7 days, whichever comes first, and stay paused for Sonarr/Radarr to import.

### API command to change:
```bash
curl -s -X POST "http://localhost:8080/api/v2/app/setPreferences" \
  --data 'json={
    "max_ratio_enabled": true,
    "max_ratio": 2.0,
    "max_seeding_time_enabled": true,
    "max_seeding_time": 168,
    "max_ratio_act": 0
  }'
```

---

## 2026-07-09 Disk Full Incident

**What happened:**
1. Sonarr downloaded 4 Sopranos REMUX packs (S03–S06, ~135-237GB each)
2. Files were **copied** (not hardlinked) from downloads to TV → 2× space usage
3. S03 + S05 finished and were imported, creating ~546G of data from ~273G of content
4. S04 + S06 stuck at 33-35% with no disk space remaining
5. Disk hit 100% → Sonarr SQLite DB got disk I/O errors and crashed
6. Plex went offline (couldn't write to its DB either)

**What was done:**
- Deleted all Sopranos REMUX packs from both TV and downloads
- Deleted Interstellar REMUX duplicate from downloads
- Set qBittorrent seeding limits (was unlimited → ratio 2.0 or 7 days)
- Fixed Docker volumes to use single `/media` mount for hardlink support
- Updated Sonarr root folder from `/data/tv` to `/media/tv`
- Recovered from 0% → 12% disk usage (107G used, 784G free)

**Lesson**: With hardlinks, REMUX packs consume ~135G per season, not ~270G. Combined with seeding limits, the disk can't fill up from stale seed data.

---

## Container Management

```bash
# Restart a service
docker compose -f /mnt/media/docker-compose.yml up -d sonarr

# View logs
docker logs sonarr --tail 50

# Access Sonarr API
curl -s "http://localhost:8989/api/v3/queue?apikey=$(grep ApiKey /mnt/media/config/sonarr/config.xml | sed 's/.*<ApiKey>//;s/<\/ApiKey>//')"

# Access qBittorrent API
curl -s "http://localhost:8080/api/v2/torrents/info"
```

---

## *Arr Import Failures Due to Path Mismatch (2026-07-09)

**Symptom:** Torrent completes in qBittorrent (100%, seeding), but Radarr/Sonarr queue stays empty and the file never imports. The `HasFile` flag stays `False` in the movie/show library, even though the file is sitting on disk.

**Root Cause — Two bugs that compound:**

### Bug 1: qBittorrent Category save_path Mismatch

The `radarr` category in qBittorrent (`/mnt/media/config/qbittorrent/config/categories.json`) had:
```json
"save_path": "/downloads"
```

But inside the qBittorrent container, `/downloads` doesn't exist — only `/media/downloads` exists (mapped from `/mnt/media/downloads`). This causes qBittorrent to silently fall back to its default save path (`/media/downloads`), but the torrent thinks it's using the category path. When Radarr polls qBittorrent for the torrent's save path, it gets `/media/downloads/...` instead of the expected `/downloads/...`.

**Fix:**
```json
"save_path": "/media/downloads"
```

### Bug 2: Missing Remote Path Mappings in Radarr

Even when qBittorrent correctly reports `/media/downloads/` as the save path, Radarr's remote path mappings didn't cover that path. The existing mappings only covered:
- `/data/downloads/` → `/downloads/`
- `/app/qBittorrent/downloads/` → `/downloads/`

**Fix:** Add the missing mapping via Radarr API:
```bash
curl -X POST "http://localhost:7878/api/v3/remotePathMapping?apiKey=<RADARR_API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{
    "host": "192.168.68.63",
    "remotePath": "/media/downloads/",
    "localPath": "/downloads/"
  }'
```

### Verification

Check the current remote path mappings:
```bash
curl -s "http://localhost:7878/api/v3/remotePathMapping?apiKey=<APIKEY>" | python3 -m json.tool
```

Check the qBittorrent category config:
```bash
python3 -m json.tool /mnt/media/config/qbittorrent/config/categories.json
```

### Manual Import (Workaround for Stuck Downloads)

If a download is already stuck (queue empty, file on disk but not imported), use Radarr's manual import:

1. **Scan the folder** — confirm Radarr can see the file:
   ```bash
   curl -s "http://localhost:7878/api/v3/manualimport?apiKey=<KEY>&folder=/downloads/RELEASE_NAME"
   ```
   If it returns 0 items, the path mapping isn't working yet.

2. **Trigger import**:
   ```bash
   curl -X POST "http://localhost:7878/api/v3/command?apiKey=<KEY>" \
     -H "Content-Type: application/json" \
     -d '{
       "name": "ManualImport",
       "importMode": "auto",
       "files": [{
         "path": "/downloads/RELEASE_NAME/RELEASE_FILE.mkv",
         "folderName": "RELEASE_NAME",
         "movieId": <MOVIE_ID>,
         "quality": {"quality": {"id": 18, "name": "WEBDL-2160p", "source": "webdl", "resolution": 2160}},
         "languages": [{"id": 1, "name": "English"}],
         "releaseGroup": "GROUP_NAME",
         "replaceExistingFiles": true
       }]
     }'
   ```

### Prevention

- The qBittorrent category save path must use the **container-internal** path (e.g., `/media/downloads`), not a path that only exists on the host.
- Any new category created in qBittorrent for an *arr app must have a corresponding remote path mapping in that *arr app's settings.
- After changing categories.json, restart qBittorrent (`docker compose restart qbittorrent`) for new torrents to use the corrected path.

---

## 2026-07-10 Legends (2026) Download Incident

**What happened:**
1. Added "Legends (2026)" (TVDB 453615) to Sonarr — 6 episodes, S01
2. Sonarr search returned 0 results because 1337x indexer was backoffed (6+ hours of failures in Prowlarr)
3. Manually found releases via LimeTorrents (2160p NF WEB-DL, Dolby Atmos, 6.7-10.3GB each)
4. Added to qBittorrent with **wrong category**: `radarr` instead of `tv-sonarr`
5. Sonarr couldn't see the torrents — wrong category, so queue stayed empty
6. qBittorrent had `max_ratio_act=1` (remove on ratio hit) — Sonarr warned about premature removal

**What was done:**
- Changed all Legend torrents category from `radarr` → `tv-sonarr` via qBittorrent API
- Ran `DownloadedEpisodesScan` in Sonarr — imported 4 completed episodes via hardlink
- Changed `max_ratio_act` from `1` (remove) to `0` (pause) in qBittorrent
- 2 remaining episodes (E05, E06) still downloading — auto-import when complete

**Lessons:**
- When adding torrents manually to qBittorrent for an *arr app, always use the correct category (`tv-sonarr` for Sonarr, `radarr` for Radarr)
- If Sonarr search returns 0 results, check indexer health via Prowlarr before troubleshooting further
- `max_ratio_act=1` is risky — change to `0` unless you're sure Sonarr/Radarr will import fast enough
- Prowlarr indexers can go down individually — check with: `curl -s "http://localhost:9696/api/v1/search?query=test&indexerIds=N"` (1=1337x, 4=LimeTorrents)

---

## Manually Adding a TV Show When Indexers Are Backoffed

If Sonarr's automatic search fails due to indexer backoff, you can still grab releases via Prowlarr's API directly and add them to qBittorrent:

### 1. Search via Prowlarr
```bash
PROMARR_KEY="$(grep ApiKey /mnt/media/config/prowlarr/config.xml | sed 's/.*<ApiKey>//;s/<\\/ApiKey>//')"
curl -s "http://localhost:9696/api/v1/search?query=SHOW+NAME+2160p&limit=20&apiKey=$PROMARR_KEY" --max-time 45
```
> Note: Indexer IDs vary. Check Prowlarr settings → Indexers for the correct IDs.

### 2. Add to qBittorrent with the Correct Category
```bash
# Get the magnet link
curl -sL -o /dev/null -w '%{redirect_url}' "PROWLARR_DOWNLOAD_URL"

# Add to qBittorrent with category tv-sonarr or radarr
curl -s -b /tmp/qb_cookies -X POST 'http://localhost:8080/api/v2/torrents/add' \
  -F 'urls=MAGNET_LINK' \
  -F 'savepath=/media/downloads' \
  -F 'category=tv-sonarr'  # ← CRITICAL: must match the *arr app's category
```

### 3. Trigger Sonarr Import
Once torrents complete, Sonarr auto-imports them if the category is correct. Alternatively:
```bash
curl -X POST "http://localhost:8989/api/v3/command?apiKey=$SONARR_KEY" \
  -H "Content-Type: application/json" \
  -d '{"name": "DownloadedEpisodesScan"}'
```

---

## Useful URL

Dashboard: `http://192.168.68.63:5000/entertainment/` — unified hub with links to all services

Sonarr API key:
```
grep ApiKey /mnt/media/config/sonarr/config.xml
```

qBittorrent WebUI: `http://192.168.68.63:8080` (credentials in docker-compose.yml)
