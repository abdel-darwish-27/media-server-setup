#!/bin/bash
# Batch strip Dolby Vision from Legends S01 E02-E06
# FPS is 25/1 for this UK show — explicitly set to keep audio sync
set -euo pipefail

SEASON_DIR="/mnt/media/tv/Legends (2026)/Season 1"
DESKTOP_BACKUP="/home/barry/Desktop"
FPS="25/1"

process_episode() {
    local infile="$1"
    local basename=$(basename "$infile" .mkv)
    local output="/tmp/${basename}.HDR10.mkv"
    local backup="${DESKTOP_BACKUP}/Legends.${basename#Legends 2026 S01E}.ORIGINAL.mkv"

    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  Processing: $basename"
    echo "═══════════════════════════════════════════════════════════"

    # 0. Check if it has DV
    echo "→ Checking for DV..."
    if ! ffmpeg -hide_banner -i "$infile" 2>&1 | grep -q "DOVI"; then
        echo "  ⏭  No DV metadata found — skipping"
        return 0
    fi

    # 1. Backup to Desktop
    echo "→ Backing up to Desktop..."
    cp "$infile" "$backup"
    echo "  ✓ Backup: $backup"

    # 2. Extract video
    echo "→ Extracting raw HEVC video..."
    mkvextract tracks "$infile" 0:/tmp/dv_video.hevc 2>/dev/null

    # 3. Strip DV
    echo "→ Demuxing DV layer..."
    dovi_tool demux -i /tmp/dv_video.hevc -b /tmp/dv_bl.hevc -e /tmp/dv_el.hevc 2>/dev/null

    # 4. Extract all non-video tracks
    echo "→ Extracting audio/subtitle tracks..."
    local total=$(mkvmerge -i "$infile" 2>/dev/null | grep -c "Track ID")
    for i in $(seq 1 $((total - 1))); do
        mkvextract tracks "$infile" $i:/tmp/dv_track_$i 2>/dev/null
    done

    # 5. Remux with explicit framerate
    echo "→ Remuxing HDR10 (FPS: $FPS)..."
    local mkvmerge_args=(-o "$output" --default-duration "0:${FPS}fps" /tmp/dv_bl.hevc)
    for f in /tmp/dv_track_*; do
        if [ -s "$f" ]; then
            mkvmerge_args+=("$f")
        fi
    done
    mkvmerge "${mkvmerge_args[@]}" 2>/dev/null

    # 6. Verify clean
    if ffmpeg -hide_banner -i "$output" 2>&1 | grep -q "DOVI"; then
        echo "  ⚠️  DV still present in output!"
        exit 1
    fi
    echo "  ✓ DV clean"

    # 7. Replace original
    echo "→ Replacing original..."
    mv "$infile" "${infile}.DELETEME"  # hold in case of issues
    mv "$output" "$infile"
    rm -f "${infile}.DELETEME"

    # 8. Cleanup
    rm -f /tmp/dv_video.hevc /tmp/dv_bl.hevc /tmp/dv_el.hevc /tmp/dv_track_*

    echo "  ✓ Done!"
}

for ep in "$SEASON_DIR"/Legends\ 2026\ S01E0[2-6]*.mkv; do
    if [ -f "$ep" ]; then
        process_episode "$ep"
    fi
done

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  All episodes processed! Only Desktop backups remain."
ls -1 "$SEASON_DIR"/
echo "═══════════════════════════════════════════════════════════"
