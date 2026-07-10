## Dolby Vision Stripping

If a 4K movie has weird colours on your TV, it likely has Dolby Vision metadata your TV handles badly.
The fix extracts the HDR10 base layer and strips the Dolby Vision enhancement metadata.

### Critical: Audio Sync & Subtitle Defaults

**Audio sync:** The `--default-duration` flag in mkvmerge must match the source framerate. UK shows are often **25fps** (PAL), not 23.976fps. Using the wrong framerate causes audio drift. The script auto-detects via `ffprobe`.

**Subtitle defaults:** mkvextract loses language tags (all become `und`) and mkvmerge resets default/forced flags. This causes Plex to auto-show subtitles. The script now runs `mkvpropedit` after remuxing to set `language=en` and `flag-default=0` on all subtitle tracks.

### One-liner (for a file already downloaded)

```bash
sudo apt install mkvtoolnix   # if not installed
./scripts/strip_dolby_vision.sh /path/to/movie.mkv
```

This produces a clean HDR10 file at `/path/to/movie.HDR10.mkv`.
Swap it in place of the original and Plex will pick it up.

### Full pipeline (manual, step-by-step)

```bash
# 1. BACKUP FIRST!
cp input.mkv ~/Desktop/input.ORIGINAL.mkv

# 2. Extract raw HEVC
mkvextract tracks input.mkv 0:/tmp/video.hevc

# 3. Download dovi_tool (run once)
curl -sL -o /tmp/dovi_tool.tar.gz "https://github.com/quietvoid/dovi_tool/releases/download/2.3.2/dovi_tool-2.3.2-x86_64-unknown-linux-musl.tar.gz"
cd /tmp && tar -xzf dovi_tool.tar.gz && chmod +x dovi_tool
mkdir -p ~/.local/bin && cp /tmp/dovi_tool ~/.local/bin/

# 4. Strip DV (keeps HDR10 base layer)
~/.local/bin/dovi_tool demux -i /tmp/video.hevc -b /tmp/bl.hevc -e /tmp/el.hevc

# 5. Extract all audio/subtitle tracks
for i in $(seq 1 $(mkvmerge -i input.mkv 2>/dev/null | grep -c "Track ID")); do
    mkvextract tracks input.mkv $i:/tmp/track_$i
done

# 6. Remux without DV (CRITICAL: use correct framerate!)
FPS=$(ffprobe -v error -select_streams v:0 -show_entries stream=avg_frame_rate -of default=noprint_wrappers=1:nokey=1 input.mkv 2>/dev/null)
mkvmerge -o output.mkv --default-duration "0:${FPS:-24000/1001}fps" /tmp/bl.hevc /tmp/track_*

# 7. Fix subtitle language tags (Plex will show subs by default without this!)
TOTAL=$(mkvmerge -i output.mkv 2>/dev/null | grep -c "subtitles")
for i in $(seq 2 $((TOTAL + 1))); do
    mkvpropedit output.mkv --edit track:$i --set language=en --set flag-default=0
done

# 8. Clean up
rm -f /tmp/video.hevc /tmp/bl.hevc /tmp/el.hevc /tmp/track_*

# 9. Replace original
mv input.mkv input.mkv.ORIGINAL.BAK
mv output.mkv input.mkv

# 10. Trigger Plex scan
curl "http://localhost:32400/library/sections/1/refresh?X-Plex-Token=<TOKEN>"
```

### Why this works

Profile 8 Dolby Vision files carry DV as metadata on top of a standard HDR10 base layer.
`dovi_tool demux` separates the base layer (HDR10, video only) from the enhancement layer (DV).
We discard the enhancement layer and remux just the base layer with all original audio/subtitle tracks.
`mkvmerge --default-duration` ensures proper HEVC timing headers are preserved during remux — **critical for audio sync**.

### Step 5 restores language tags because:
- `mkvextract` extracts tracks as raw streams with no metadata
- `mkvmerge` sets all subtitle language to `und` (undefined) and may set default flags
- Plex sees `und` tracks and may auto-enable subtitles
- The fix sets all tracks to `language=en` and `flag-default=0` so no subtitles show by default

### Tools needed

- `mkvtoolnix` (provides mkvextract, mkvmerge, mkvpropedit) — `sudo apt install mkvtoolnix`
- `dovi_tool` — download binary from GitHub releases
- Standard ffmpeg for verification

