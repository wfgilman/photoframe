#!/bin/bash
PHOTOS_DIR="__HOME__/photos"
ROTATED_DIR="__HOME__/photos_rotated"
CONFIG_FILE="__HOME__/.photo_bot_config.json"
RESCAN_EVERY=60
mkdir -p "$ROTATED_DIR"

get_interval() {
    if [ -f "$CONFIG_FILE" ]; then
        val=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('interval', 15))" 2>/dev/null)
        echo "${val:-15}"
    else
        echo 15
    fi
}

# Signature of the source photo set; changes whenever a photo is added/removed.
source_signature() {
    (cd "$PHOTOS_DIR" 2>/dev/null && ls -1 *.jpg 2>/dev/null | sort) | sha1sum | cut -d' ' -f1
}

rotate_photos() {
    # Drop rotated copies whose source is gone (e.g. deleted via reaction).
    for f in "$ROTATED_DIR"/*.jpg; do
        [ -f "$f" ] || continue
        base=$(basename "$f")
        [ -f "$PHOTOS_DIR/$base" ] || rm -f "$f"
    done
    # Rotate only photos that don't already have a cached copy.
    for f in "$PHOTOS_DIR"/*.jpg; do
        [ -f "$f" ] || continue
        base=$(basename "$f")
        [ -f "$ROTATED_DIR/$base" ] && continue
        python3 -c "
from PIL import Image, ImageOps
img = Image.open('$f')
try: img = ImageOps.exif_transpose(img)
except: pass
img = ImageOps.fit(img, (600, 1024), Image.LANCZOS)
img.rotate(90, expand=True).save('$ROTATED_DIR/$base')
"
    done
}

last_sig=""
last_interval=""

while true; do
    rotate_photos
    sig=$(source_signature)
    interval=$(get_interval)

    need_restart=false
    [ "$sig" != "$last_sig" ] && need_restart=true
    [ "$interval" != "$last_interval" ] && need_restart=true
    pgrep -x fbi >/dev/null 2>&1 || need_restart=true

    if $need_restart; then
        # Pre-shuffle so fbi cycles through every photo before repeating.
        mapfile -t FILES < <(find "$ROTATED_DIR" -maxdepth 1 -name '*.jpg' | shuf)
        if [ ${#FILES[@]} -eq 0 ]; then
            echo "No photos. Waiting..."
            sleep 30
            continue
        fi
        killall fbi 2>/dev/null
        sleep 0.5
        openvt -s -f -- fbi --noverbose --nocomments --autozoom \
            --timeout "$interval" "${FILES[@]}" &
        echo "Showing ${#FILES[@]} photos, ${interval}s interval (sig=${sig:0:8})"
        last_sig=$sig
        last_interval=$interval
    fi

    sleep "$RESCAN_EVERY"
done
