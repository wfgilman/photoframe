#!/bin/bash
set -e

# ── Photoframe Installer ───────────────────────────────────────────────────
# Sets up the Telegram photo bot and fbi slideshow on a Raspberry Pi.
#
# Usage:
#   git clone https://github.com/youruser/photoframe.git
#   cd photoframe
#   sudo ./install.sh
#

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_USER="${SUDO_USER:-$USER}"
INSTALL_HOME="$(eval echo ~"$INSTALL_USER")"
CMDLINE="/boot/firmware/cmdline.txt"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*"; exit 1; }

# ── Preflight ───────────────────────────────────────────────────────────────

if [ "$(id -u)" -ne 0 ]; then
    error "Run with sudo: sudo ./install.sh"
fi

if [ -z "$INSTALL_USER" ] || [ "$INSTALL_USER" = "root" ]; then
    error "Don't run as root directly. Use: sudo ./install.sh"
fi

info "Installing photoframe for user: $INSTALL_USER ($INSTALL_HOME)"

# ── Telegram bot token ──────────────────────────────────────────────────────

BOT_TOKEN=""
# Check if already configured in an existing service file
if [ -f /etc/systemd/system/photo_bot.service ]; then
    EXISTING_TOKEN=$(grep -oP 'TELEGRAM_BOT_TOKEN=\K[^"]+' /etc/systemd/system/photo_bot.service 2>/dev/null || true)
    if [ -n "$EXISTING_TOKEN" ] && [ "$EXISTING_TOKEN" != "PUT_YOUR_TOKEN_HERE" ]; then
        info "Found existing bot token in photo_bot.service"
        BOT_TOKEN="$EXISTING_TOKEN"
    fi
fi

if [ -z "$BOT_TOKEN" ]; then
    echo ""
    echo "To set up the Telegram bot:"
    echo "  1. Open Telegram, message @BotFather"
    echo "  2. Send /newbot, pick a name"
    echo "  3. Copy the bot token"
    echo ""
    read -rp "Paste your Telegram bot token (or Enter to skip): " BOT_TOKEN
    if [ -z "$BOT_TOKEN" ]; then
        BOT_TOKEN="PUT_YOUR_TOKEN_HERE"
        warn "Skipped — edit /etc/systemd/system/photo_bot.service to add your token later"
    fi
fi

# ── Install system packages ─────────────────────────────────────────────────

info "Installing system packages..."
apt-get update -qq
apt-get install -y -qq python3-pil python3-numpy python3-requests fbi > /dev/null
info "Packages installed"

# ── Copy application files ──────────────────────────────────────────────────

info "Copying files to $INSTALL_HOME..."
mkdir -p "${INSTALL_HOME}/photos"

# photo_bot.py — no templating needed, uses env var and Path.home()
cp "$REPO_DIR/photo_bot.py" "${INSTALL_HOME}/photo_bot.py"

# slideshow.sh — substitute home directory
sed "s|__HOME__|${INSTALL_HOME}|g" "$REPO_DIR/slideshow.sh" \
    > "${INSTALL_HOME}/slideshow.sh"
chmod +x "${INSTALL_HOME}/slideshow.sh"

chown "$INSTALL_USER:$INSTALL_USER" \
    "${INSTALL_HOME}/photo_bot.py" \
    "${INSTALL_HOME}/slideshow.sh" \
    "${INSTALL_HOME}/photos"

# ── Install systemd services ────────────────────────────────────────────────

info "Installing systemd services..."

for svc in "$REPO_DIR"/systemd/*.service; do
    name="$(basename "$svc")"
    sed \
        -e "s|__USER__|${INSTALL_USER}|g" \
        -e "s|__HOME__|${INSTALL_HOME}|g" \
        -e "s|__BOT_TOKEN__|${BOT_TOKEN}|g" \
        "$svc" > "/etc/systemd/system/$name"
    info "  Installed $name"
done

systemctl daemon-reload

# ── Configure boot parameters ───────────────────────────────────────────────

info "Configuring boot parameters..."
CMDLINE_CHANGED=false

add_cmdline_param() {
    local param="$1"
    if ! grep -q "$param" "$CMDLINE" 2>/dev/null; then
        # Append to the single line in cmdline.txt
        sed -i "s/$/ $param/" "$CMDLINE"
        info "  Added $param"
        CMDLINE_CHANGED=true
    fi
}

# Map console to nonexistent framebuffer (frees fb0 for slideshow)
add_cmdline_param "fbcon=map:9"
# Disable screen blanking
add_cmdline_param "consoleblank=0"
# Hide boot noise
add_cmdline_param "logo.nologo"
add_cmdline_param "quiet"
add_cmdline_param "loglevel=1"
# Hide blinking cursor
add_cmdline_param "vt.global_cursor_default=0"

# ── Enable services ─────────────────────────────────────────────────────────

info "Enabling services..."
systemctl enable photo_bot.service
systemctl enable slideshow.service

# ── Done ────────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════════════════"
info "Installation complete!"
echo ""
echo "  Files:"
echo "    ${INSTALL_HOME}/photo_bot.py"
echo "    ${INSTALL_HOME}/slideshow.sh"
echo "    ${INSTALL_HOME}/photos/"
echo ""
echo "  Services:"
echo "    photo_bot.service  (Telegram sync)"
echo "    slideshow.service  (fbi display)"
echo ""
echo "  Useful commands:"
echo "    sudo systemctl status photo_bot"
echo "    sudo systemctl status slideshow"
echo "    journalctl -u photo_bot -f"
echo "    cat ${INSTALL_HOME}/photo_bot.log"
echo ""

if [ "$CMDLINE_CHANGED" = true ]; then
    warn "Boot parameters changed — reboot required."
    read -rp "Reboot now? [y/N] " REBOOT
    if [[ "$REBOOT" =~ ^[Yy] ]]; then
        info "Rebooting..."
        reboot
    else
        echo "  Run 'sudo reboot' when ready."
    fi
else
    info "Starting services..."
    systemctl start photo_bot.service
    systemctl start slideshow.service
fi
