#!/bin/bash
PHOTOS_DIR="__HOME__/photos"
ROTATED_DIR="__HOME__/photos_rotated"
CONFIG_FILE="__HOME__/.photo_bot_config.json"
# Photos already shown in the current round, one path per line. Every photo
# is shown once, in random order, before any photo repeats. Keeping this on
# disk lets reboots, deletions and /delay changes resume the round instead
# of reshuffling from scratch and replaying whatever lands up front.
SHOWN_FILE="__HOME__/.slideshow_shown"
RESCAN_EVERY=60
mkdir -p "$ROTATED_DIR"
touch "$SHOWN_FILE"

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
        base=${f##*/}
        [ -f "$PHOTOS_DIR/$base" ] || rm -f "$f"
    done
    # Rotate only photos that don't already have a cached copy.
    for f in "$PHOTOS_DIR"/*.jpg; do
        [ -f "$f" ] || continue
        base=${f##*/}
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

all_photos() {
    find "$ROTATED_DIR" -maxdepth 1 -name '*.jpg' | sort
}

# Photos not yet shown this round, in random order.
unshown_photos() {
    comm -23 <(all_photos) <(sort "$SHOWN_FILE") | shuf
}

# Add the first $1 playlist entries to the round, dropping deleted photos.
record_shown() {
    { cat "$SHOWN_FILE"; printf '%s\n' "${FILES[@]:0:$1}"; } \
        | sort -u | comm -12 - <(all_photos) > "$SHOWN_FILE.tmp"
    mv "$SHOWN_FILE.tmp" "$SHOWN_FILE"
}

# fbi gives each slide one interval, so elapsed time says how far into the
# playlist it is. Credit shown slides so a restart skips them; the one on
# screen counts once it has had half its time.
credit_progress() {
    elapsed=$(( $(date +%s) - last_restart ))
    [ ${#FILES[@]} -gt 0 ] || return 0
    played=$(( (2 * elapsed + last_interval) / (2 * last_interval) ))
    [ "$played" -gt ${#FILES[@]} ] && played=${#FILES[@]}
    if [ "$played" -gt "$credited" ]; then
        record_shown "$played"
        credited=$played
        last_shown=${FILES[played-1]}
    fi
}

FILES=()      # current fbi playlist, in display order
credited=0    # how many of FILES are already in SHOWN_FILE
last_shown=""
last_sig=""
last_interval=""
last_restart=0

# Save progress on stop (/reinstall, reboots) so the round resumes exactly.
trap 'credit_progress; exit 0' TERM

while true; do
    rotate_photos
    sig=$(source_signature)
    interval=$(get_interval)
    credit_progress

    need_restart=false
    pgrep -x fbi >/dev/null 2>&1 || need_restart=true
    [ "$sig" != "$last_sig" ] && need_restart=true
    [ "$interval" != "$last_interval" ] && need_restart=true
    # Playlist done: reshuffle for the next round rather than letting fbi
    # loop the same order. A lone photo has nothing to reshuffle.
    if [ ${#FILES[@]} -gt 0 ] && [ "$elapsed" -ge $(( ${#FILES[@]} * last_interval )) ] \
        && [ "$(all_photos | wc -l)" -gt 1 ]; then
        need_restart=true
    fi

    if $need_restart; then
        round="Resuming round"
        mapfile -t FILES < <(unshown_photos)
        if [ ${#FILES[@]} -eq 0 ]; then
            # Every photo has had its turn; start a new round.
            round="New round"
            : > "$SHOWN_FILE"
            mapfile -t FILES < <(unshown_photos)
            # Don't open the round with the photo that just closed the last one.
            if [ ${#FILES[@]} -gt 1 ] && [ "${FILES[0]}" = "$last_shown" ]; then
                FILES=("${FILES[@]:1}" "${FILES[0]}")
            fi
        fi
        if [ ${#FILES[@]} -eq 0 ]; then
            echo "No photos. Waiting..."
            sleep 30
            continue
        fi
        killall fbi 2>/dev/null
        sleep 0.5
        openvt -s -f -- fbi --noverbose --nocomments --autozoom \
            --timeout "$interval" "${FILES[@]}" &
        echo "$round: ${#FILES[@]} of $(all_photos | wc -l | tr -d ' ') photos to go, ${interval}s interval (sig=${sig:0:8})"
        credited=0
        last_sig=$sig
        last_interval=$interval
        # Backdated a second so the round-end restart lands just before fbi
        # would loop back and flash the first slide of the old order.
        last_restart=$(( $(date +%s) - 1 ))
    fi

    # Wake when the playlist runs out so the next round starts on time.
    left=$(( last_restart + ${#FILES[@]} * last_interval - $(date +%s) ))
    [ "$left" -gt 0 ] && [ "$left" -lt "$RESCAN_EVERY" ] || left=$RESCAN_EVERY
    sleep "$left"
done
