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

Requires Raspberry Pi OS **Bookworm** or newer (NetworkManager is the default there). On older images, enable NetworkManager via `sudo raspi-config → Advanced Options → Network Config → NetworkManager` first.

## Portable WiFi setup

On boot, if the Pi can't join a known network, it runs a one-time provisioning flow so you can move the frame to any WiFi — no re-flashing, no hardcoded credentials.

1. Display shows a setup screen with two QR codes.
2. Scan the first QR to connect your phone to the Pi's hotspot (`PhotoFrame-Setup` / password `photoframe`).
3. Scan the second QR (or visit `http://10.42.0.1`) to open the setup page.
4. Pick your WiFi network, enter the password, tap **Connect**. The hotspot shuts down and the slideshow starts.

Once configured, the frame skips setup on every subsequent boot.

**Moving the frame to a new network just works.** A watchdog (`wifi_watchdog.service`) monitors the WiFi link, and if the frame can't maintain any active network connection for 5 minutes, it reboots. Since no saved network is in range at the new location, the boot-time setup flow re-runs automatically and the setup screen reappears.

To force a reset on demand (e.g. you want to switch networks even though the current one is still reachable):

```bash
# Over SSH on the current network:
touch ~/.reset_wifi && sudo reboot

# Or offline: put the SD card in a computer and create an empty file
#   `wifi-reset` on the FAT32 boot partition (/boot/firmware/wifi-reset).
```

On next boot the saved credentials are cleared and the setup screen reappears.

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
| `/ip` | Show IP, hostname, and SSID (for SSH access) |
| `/help` | Show available commands |

Send photos to add. React 👎 ⛔ 🚫 ❌ to remove.

## Display configuration

The slideshow is configured for a 1024×600 framebuffer mounted in portrait orientation (90° rotation). To adjust for a different display, edit the `ImageOps.fit()` dimensions and rotation in `slideshow.sh`.

## What the installer does

1. Installs apt packages: `python3-pil`, `python3-numpy`, `python3-requests`, `python3-qrcode`, `fbi`, `fonts-dejavu-core`
2. Copies `photo_bot.py`, `wifi_setup.py`, and `slideshow.sh` to `~/`
3. Installs systemd services with your username and bot token
4. Adds boot parameters to `/boot/firmware/cmdline.txt`:
   - `fbcon=map:9` — maps console to nonexistent framebuffer (frees fb0)
   - `consoleblank=0` — disables screen blanking
   - `logo.nologo quiet loglevel=1` — hides boot messages
   - `vt.global_cursor_default=0` — hides blinking cursor

## Installed file layout

```
~/photo_bot.py             # Telegram bot daemon
~/wifi_setup.py            # WiFi provisioning (runs at boot)
~/slideshow.sh             # fbi slideshow loop
~/photos/                  # Raw photos from Telegram
~/photos_rotated/          # Processed photos (auto-generated)
~/photo_bot.log            # Bot log output
~/wifi_setup.log           # WiFi setup log
~/.photo_bot_state.json    # Bot state (auto-generated)
~/.photo_bot_config.json   # Runtime config (from /delay command)
~/.reset_wifi              # Touch to clear saved WiFi on next boot
```

## Useful commands

```bash
# Service status
sudo systemctl status photo_bot
sudo systemctl status slideshow
sudo systemctl status wifi_setup
sudo systemctl status wifi_watchdog

# Live logs
journalctl -u photo_bot -f
journalctl -u slideshow -f
journalctl -u wifi_setup -f

# Bot log
tail -f ~/photo_bot.log
tail -f ~/wifi_setup.log

# Restart after changes
sudo systemctl restart photo_bot
sudo systemctl restart slideshow

# Re-provision WiFi (clears saved network, shows setup screen after reboot)
touch ~/.reset_wifi && sudo reboot
```

## Uninstall

```bash
cd photoframe
sudo ./uninstall.sh
```

Stops services, removes scripts and service files. Keeps your photos.

## License

MIT
