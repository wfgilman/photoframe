#!/bin/bash
PHOTOS_DIR="__HOME__/photos"
ROTATED_DIR="__HOME__/photos_rotated"
CONFIG_FILE="__HOME__/.photo_bot_config.json"
RESCAN_EVERY=300
mkdir -p "$ROTATED_DIR"
get_interval() {
    if [ -f "$CONFIG_FILE" ]; then
        val=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('interval', 15))" 2>/dev/null)
        echo "${val:-15}"
    else
        echo 15
    fi
}
rotate_photos() {
    rm -f "$ROTATED_DIR"/*.jpg
    for f in "$PHOTOS_DIR"/*.jpg; do
        [ -f "$f" ] || continue
        python3 -c "
from PIL import Image, ImageOps
img = Image.open('$f')
try: img = ImageOps.exif_transpose(img)
except: pass
img = ImageOps.fit(img, (600, 1024), Image.LANCZOS)
img.rotate(90, expand=True).save('$ROTATED_DIR/$(basename "$f")')
"
    done
}
while true; do
    rotate_photos
    INTERVAL=$(get_interval)
    FILES=("$ROTATED_DIR"/*.jpg)
    if [ ${#FILES[@]} -eq 0 ]; then
        echo "No photos. Waiting..."
        sleep 30
        continue
    fi
    killall fbi 2>/dev/null
    sleep 0.5
    openvt -s -f -- fbi --noverbose --nocomments --autozoom \
        --timeout "$INTERVAL" --random "${FILES[@]}" &
    echo "Showing ${#FILES[@]} photos, ${INTERVAL}s interval"
    sleep "$RESCAN_EVERY"
done
