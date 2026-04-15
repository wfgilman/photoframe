#!/usr/bin/env python3
"""
Telegram Photo Bot for Pi Zero photo frame.

- Polls Telegram for new photos sent to the bot's group/channel.
- Downloads them to ~/photos/.
- Watches for 👎 or ⛔ reactions and deletes the corresponding file.
- Tracks state (last update id + message_id->filename) in ~/.photo_bot_state.json.
- Supports /delay <seconds> to configure slideshow interval.

Setup:
  1. Create bot via @BotFather, get token.
  2. Create a private group, add the bot, promote to admin (required for reactions).
  3. Set BOT_TOKEN below (or via env var).
  4. Run: python3 photo_bot.py
  5. Install as systemd service for auto-start (see photo_bot.service).
"""

import json
import os
import sys
import time
from pathlib import Path

import requests

BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "PUT_YOUR_TOKEN_HERE")
PHOTOS_DIR = Path.home() / "photos"
STATE_FILE = Path.home() / ".photo_bot_state.json"
CONFIG_FILE = Path.home() / ".photo_bot_config.json"
POLL_INTERVAL = 30  # seconds
DELETE_REACTIONS = {"👎", "⛔", "🚫", "❌"}

API = f"https://api.telegram.org/bot{BOT_TOKEN}"
FILE_API = f"https://api.telegram.org/file/bot{BOT_TOKEN}"


def load_state():
    if STATE_FILE.exists():
        return json.loads(STATE_FILE.read_text())
    return {"last_update_id": 0, "messages": {}}  # messages: {chat_id:msg_id -> filename}


def save_state(state):
    STATE_FILE.write_text(json.dumps(state, indent=2))


def load_config():
    if CONFIG_FILE.exists():
        return json.loads(CONFIG_FILE.read_text())
    return {}


def save_config(config):
    CONFIG_FILE.write_text(json.dumps(config, indent=2))


def get_updates(offset):
    r = requests.get(
        f"{API}/getUpdates",
        params={
            "offset": offset,
            "timeout": 25,
            "allowed_updates": json.dumps(["message", "channel_post", "message_reaction"]),
        },
        timeout=30,
    )
    r.raise_for_status()
    return r.json().get("result", [])


def download_photo(file_id, dest_name):
    # Get file path
    r = requests.get(f"{API}/getFile", params={"file_id": file_id}, timeout=15)
    r.raise_for_status()
    file_path = r.json()["result"]["file_path"]

    # Download
    url = f"{FILE_API}/{file_path}"
    r = requests.get(url, stream=True, timeout=60)
    r.raise_for_status()
    dest = PHOTOS_DIR / dest_name
    with open(dest, "wb") as f:
        for chunk in r.iter_content(chunk_size=8192):
            f.write(chunk)
    return dest


def send_message(chat_id, text):
    try:
        requests.post(
            f"{API}/sendMessage",
            json={"chat_id": chat_id, "text": text},
            timeout=10,
        )
    except Exception:
        pass  # best-effort replies


def handle_message(msg, state):
    chat_id = msg["chat"]["id"]
    msg_id = msg["message_id"]
    key = f"{chat_id}:{msg_id}"

    # Handle text commands
    text = (msg.get("text") or "").strip()

    if text.startswith("/delay"):
        parts = text.split()
        if len(parts) == 2 and parts[1].isdigit():
            seconds = int(parts[1])
            if 5 <= seconds <= 3600:
                config = load_config()
                config["interval"] = seconds
                save_config(config)
                send_message(chat_id, f"⏱️ Slide interval set to {seconds}s")
                print(f"[*] Interval set to {seconds}s")
            else:
                send_message(chat_id, "Use a value between 5 and 3600 seconds")
        else:
            config = load_config()
            current = config.get("interval", 15)
            send_message(chat_id, f"Current interval: {current}s\nUsage: /delay 30")
        return

    if text.startswith("/status"):
        config = load_config()
        interval = config.get("interval", 15)
        photo_count = len(list(PHOTOS_DIR.glob("*.jpg")))
        send_message(chat_id, f"📸 {photo_count} photos\n⏱️ {interval}s interval")
        return

    if text.startswith("/help") or text.startswith("/start"):
        send_message(
            chat_id,
            "🖼️ Photo Frame Bot\n\n"
            "Send photos → added to frame\n"
            "React 👎 ⛔ 🚫 ❌ → remove photo\n\n"
            "Commands:\n"
            "/delay <seconds> — set slide interval\n"
            "/status — show photo count & interval\n"
            "/help — this message",
        )
        return

    # Handle photos
    photos = msg.get("photo")
    if not photos:
        return

    # Use largest resolution
    largest = max(photos, key=lambda p: p.get("file_size", 0))
    file_id = largest["file_id"]

    # Filename: <chat>_<msg>.jpg
    filename = f"{chat_id}_{msg_id}.jpg"
    try:
        dest = download_photo(file_id, filename)
        state["messages"][key] = filename
        photo_count = len(list(PHOTOS_DIR.glob("*.jpg")))
        send_message(chat_id, f"✅ Photo added ({photo_count} in rotation)")
        print(f"[+] Downloaded {filename} ({dest.stat().st_size} bytes)")
    except Exception as e:
        print(f"[!] Failed to download {filename}: {e}")


def handle_reaction(reaction_update, state):
    chat_id = reaction_update["chat"]["id"]
    msg_id = reaction_update["message_id"]
    key = f"{chat_id}:{msg_id}"

    new_emojis = {r["emoji"] for r in reaction_update.get("new_reaction", []) if r.get("type") == "emoji"}
    if not (new_emojis & DELETE_REACTIONS):
        return

    filename = state["messages"].get(key)
    if not filename:
        print(f"[?] Reaction on unknown message {key}")
        return

    target = PHOTOS_DIR / filename
    if target.exists():
        target.unlink()
        print(f"[-] Deleted {filename}")
    state["messages"].pop(key, None)


def main():
    if BOT_TOKEN == "PUT_YOUR_TOKEN_HERE":
        print("ERROR: Set TELEGRAM_BOT_TOKEN env var or edit BOT_TOKEN in script.")
        sys.exit(1)

    PHOTOS_DIR.mkdir(parents=True, exist_ok=True)
    state = load_state()
    print(f"[*] Photo bot started. Photos dir: {PHOTOS_DIR}")
    print(f"[*] Last update id: {state['last_update_id']}")

    while True:
        try:
            updates = get_updates(state["last_update_id"] + 1)
            for update in updates:
                state["last_update_id"] = update["update_id"]

                if "message" in update:
                    handle_message(update["message"], state)
                elif "channel_post" in update:
                    handle_message(update["channel_post"], state)
                elif "message_reaction" in update:
                    handle_reaction(update["message_reaction"], state)

            if updates:
                save_state(state)
        except requests.RequestException as e:
            print(f"[!] Network error: {e}")
        except Exception as e:
            print(f"[!] Unexpected error: {e}")

        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
