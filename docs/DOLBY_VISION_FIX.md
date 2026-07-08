## Dolby Vision Stripping

If a 4K movie has weird colours on your TV, it likely has Dolby Vision metadata your TV handles badly.
The fix extracts the HDR10 base layer and strips the Dolby Vision enhancement metadata.

### One-liner (for a file already downloaded)

```bash
sudo apt install mkvtoolnix   # if not installed
./scripts/strip_dolby_vision.sh /path/to/movie.mkv
```

This produces a clean HDR10 file at `/path/to/movie.HDR10.mkv`.
Swap it in place of the original and Plex will pick it up.

### Full pipeline (manual)

```bash
# 1. Extract raw HEVC
mkvextract tracks input.mkv 0:/tmp/video.hevc

# 2. Download dovi_tool (run once)
curl -sL -o /tmp/dovi_tool.tar.gz "https://github.com/quietvoid/dovi_tool/releases/download/2.3.2/dovi_tool-2.3.2-x86_64-unknown-linux-musl.tar.gz"
cd /tmp && tar -xzf dovi_tool.tar.gz && chmod +x dovi_tool
sudo mv dovi_tool /usr/local/bin/

# 3. Strip DV (keeps HDR10 base layer)
dovi_tool demux -i /tmp/video.hevc -b /tmp/bl.hevc -e /tmp/el.hevc

# 4. Extract all audio/subtitle tracks
for i in $(seq 1 $(mkvmerge -i input.mkv | grep -c "Track ID")); do
    mkvextract tracks input.mkv $i:/tmp/track_$i &
done
wait

# 5. Remux without DV
mkvmerge -o output.mkv --default-duration 0:24000/1001fps /tmp/bl.hevc /tmp/track_*

# 6. Clean up
rm -f /tmp/video.hevc /tmp/bl.hevc /tmp/el.hevc /tmp/track_*

# 7. Trigger Plex scan
curl "http://localhost:32400/library/sections/1/refresh?X-Plex-Token=<TOKEN>"
```

### Why this works

Profile 8 Dolby Vision files carry DV as metadata on top of a standard HDR10 base layer.
`dovi_tool demux` separates the base layer (HDR10, video only) from the enhancement layer (DV).
We discard the enhancement layer and remux just the base layer with all original audio/subtitle tracks.
`mkvmerge --default-duration` ensures proper HEVC timing headers are preserved during remux.

### Tools needed

- `mkvtoolnix` (provides mkvextract, mkvmerge) — `sudo apt install mkvtoolnix`
- `dovi_tool` — download binary from GitHub releases
- Standard ffmpeg for verification

