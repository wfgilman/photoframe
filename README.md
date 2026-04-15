# Photoframe

A Raspberry Pi digital photo frame controlled via Telegram.

Send photos to a private Telegram bot and they appear on the frame. React with 👎 to remove them. No cloud subscriptions, no public albums, no third-party photo services.

## How it works

```
Google Photos / iCloud (phone)
  → Share to Telegram bot
    → Pi downloads photos
      → PIL rotates & crops to fill screen
        → fbi displays slideshow on framebuffer
```

## Hardware

- Raspberry Pi Zero 2 W (or any Pi with WiFi)
- Display with framebuffer (developed with Waveshare 7" 1024×600 DSI touch display)
- SD card (32GB+)

## Quick start

```bash
# On a fresh Raspberry Pi OS Bookworm Lite install:
git clone https://github.com/youruser/photoframe.git
cd photoframe
sudo ./install.sh
```

The installer prompts for your Telegram bot token, installs dependencies, copies files, configures boot parameters, and reboots.

## Creating the Telegram bot

1. Open Telegram, message **@BotFather**
2. Send `/newbot`, choose a name (e.g. "Family Frame")
3. Copy the bot token — paste it when the installer asks

For reactions to work, add the bot to a **private group** and promote it to admin, or use a 1:1 chat with the bot.

## Telegram commands

| Command | Description |
|---------|-------------|
| `/delay <seconds>` | Set slideshow interval (5–3600) |
| `/status` | Show photo count and current interval |
| `/help` | Show available commands |

Send photos to add. React 👎 ⛔ 🚫 ❌ to remove.

## Display configuration

The slideshow is configured for a 1024×600 framebuffer mounted in portrait orientation (90° rotation). To adjust for a different display, edit the `ImageOps.fit()` dimensions and rotation in `slideshow.sh`.

## What the installer does

1. Installs apt packages: `python3-pil`, `python3-numpy`, `python3-requests`, `fbi`
2. Copies `photo_bot.py` and `slideshow.sh` to `~/`
3. Installs systemd services with your username and bot token
4. Adds boot parameters to `/boot/firmware/cmdline.txt`:
   - `fbcon=map:9` — maps console to nonexistent framebuffer (frees fb0)
   - `consoleblank=0` — disables screen blanking
   - `logo.nologo quiet loglevel=1` — hides boot messages
   - `vt.global_cursor_default=0` — hides blinking cursor

## Installed file layout

```
~/photo_bot.py             # Telegram bot daemon
~/slideshow.sh             # fbi slideshow loop
~/photos/                  # Raw photos from Telegram
~/photos_rotated/          # Processed photos (auto-generated)
~/photo_bot.log            # Bot log output
~/.photo_bot_state.json    # Bot state (auto-generated)
~/.photo_bot_config.json   # Runtime config (from /delay command)
```

## Useful commands

```bash
# Service status
sudo systemctl status photo_bot
sudo systemctl status slideshow

# Live logs
journalctl -u photo_bot -f
journalctl -u slideshow -f

# Bot log
tail -f ~/photo_bot.log

# Restart after changes
sudo systemctl restart photo_bot
sudo systemctl restart slideshow
```

## Uninstall

```bash
cd photoframe
sudo ./uninstall.sh
```

Stops services, removes scripts and service files. Keeps your photos.

## License

MIT
