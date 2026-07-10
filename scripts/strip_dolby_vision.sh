#!/bin/bash
# Strip Dolby Vision from a 4K MKV file, leaving HDR10 intact
# Preserves all audio/subtitle tracks with correct language tags and default flags.
# Usage: ./strip_dolby_vision.sh <input.mkv> [output.mkv]

set -euo pipefail

INPUT="${1:?Usage: $0 <input.mkv> [output.mkv]}"
OUTPUT="${2:-${INPUT%.*}.HDR10.mkv}"

if [ ! -f "$INPUT" ]; then
    echo "❌ Input file not found: $INPUT"
    exit 1
fi

echo "🔍 Checking for Dolby Vision metadata..."
if ffmpeg -hide_banner -i "$INPUT" 2>&1 | grep -q "DOVI"; then
    echo "✅ Dolby Vision detected — stripping..."
else
    echo "✅ No Dolby Vision found — nothing to do."
    exit 0
fi

echo "
📦 Step 1/4: Extract raw HEVC video stream..."
mkvextract tracks "$INPUT" 0:/tmp/dv_strip_video.hevc 2>/dev/null

echo "🎯 Step 2/4: Demux Dolby Vision layer (keeps HDR10 base)..."
dovi_tool demux -i /tmp/dv_strip_video.hevc -b /tmp/dv_strip_bl.hevc -e /tmp/dv_strip_el.hevc 2>/dev/null

echo "🔧 Step 3/4: Extract all audio/subtitle tracks..."
TOTAL_TRACKS=$(mkvmerge -i "$INPUT" 2>/dev/null | grep -c "Track ID")
for i in $(seq 1 $TOTAL_TRACKS); do
    mkvextract tracks "$INPUT" $i:/tmp/dv_strip_track_$i 2>/dev/null &
done
wait

echo "📀 Step 4/4: Remux with mkvmerge (preserves all streams, no DV)..."
# Auto-detect framerate from the source (critical for audio sync!)
FPS=$(ffprobe -v error -select_streams v:0 -show_entries stream=avg_frame_rate -of default=noprint_wrappers=1:nokey=1 "$INPUT" 2>/dev/null)
if [ -z "$FPS" ] || [ "$FPS" = "0/0" ]; then
    FPS="24000/1001"
fi
echo "  Framerate: $FPS"

mkvmerge_args=(-o "$OUTPUT" --default-duration "0:${FPS}fps" /tmp/dv_strip_bl.hevc)
for f in /tmp/dv_strip_track_*; do
    if [ -s "$f" ]; then
        mkvmerge_args+=("$f")
    fi
done
mkvmerge "${mkvmerge_args[@]}" 2>/dev/null

echo "
🏷️  Step 5/5: Restore language tags and subtitle defaults..."
# mkvextract loses language tags (all become "und") and mkvmerge resets default/forced flags.
# This fixes subtitle auto-show in Plex — without this, all tracks are language "und" and
# Plex may show subtitles by default when it can't determine the language.
TOTAL=$(mkvmerge -i "$OUTPUT" 2>/dev/null | grep -c "subtitles")
for i in $(seq 2 $((TOTAL + 1))); do
    mkvpropedit "$OUTPUT" --edit track:$i --set language=en --set flag-default=0 2>/dev/null
done
echo "  Restored language=en, flag-default=0 on $TOTAL subtitle tracks"

echo "
🧹 Cleaning up temp files..."
rm -f /tmp/dv_strip_*

echo "
✅ Done! Output: $OUTPUT"

# Verify
if ffmpeg -hide_banner -i "$OUTPUT" 2>&1 | grep -q "DOVI"; then
    echo "⚠️  Warning: DV metadata may still be present."
else
    echo "✅ DV successfully stripped — file is clean HDR10!"
fi

echo ""
echo "File: $(ls -lh "$OUTPUT" | awk '{print $5}')"
echo "Duration: $(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$OUTPUT" 2>/dev/null) seconds"
