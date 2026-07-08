#!/bin/bash
# Strip Dolby Vision from a 4K MKV file, leaving HDR10 intact
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
# Auto-detect framerate from the source
FPS=$(ffprobe -v error -select_streams v:0 -show_entries stream=avg_frame_rate -of default=noprint_wrappers=1:nokey=1 "$INPUT" 2>/dev/null)
if [ -z "$FPS" ] || [ "$FPS" = "0/0" ]; then
    FPS="24000/1001"
fi
WARN_FPS=$(echo "$FPS" | grep -oP '^\d+')
if [ "$WARN_FPS" = "24" ] || [ "$WARN_FPS" = "23" ]; then
    true
else
    echo "⚠️  Unusual framerate detected: $FPS"
fi

mkvmerge_args=(-o "$OUTPUT" --default-duration "0:${FPS}fps" /tmp/dv_strip_bl.hevc)
for f in /tmp/dv_strip_track_*; do
    if [ -s "$f" ]; then
        mkvmerge_args+=("$f")
    fi
done
mkvmerge "${mkvmerge_args[@]}" 2>/dev/null

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
