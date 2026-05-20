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

# ── NetworkManager required (for WiFi provisioning) ─────────────────────────

if ! command -v nmcli >/dev/null 2>&1 || ! systemctl is-active --quiet NetworkManager; then
    error "NetworkManager must be the active network stack.
  Enable it via:  sudo raspi-config  →  Advanced Options  →  Network Config  →  NetworkManager
  Then re-run this installer. (Bookworm defaults to NetworkManager; older images may need this step.)"
fi

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
apt-get install -y -qq git python3-pil python3-numpy python3-requests python3-qrcode fbi fonts-dejavu-core > /dev/null
info "Packages installed"

# ── Copy application files ──────────────────────────────────────────────────

info "Copying files to $INSTALL_HOME..."
mkdir -p "${INSTALL_HOME}/photos"

# photo_bot.py — no templating needed, uses env var and Path.home()
cp "$REPO_DIR/photo_bot.py" "${INSTALL_HOME}/photo_bot.py"

# wifi_setup.py — substitute home directory for reset-flag path
sed "s|__HOME__|${INSTALL_HOME}|g" "$REPO_DIR/wifi_setup.py" \
    > "${INSTALL_HOME}/wifi_setup.py"

# slideshow.sh — substitute home directory
sed "s|__HOME__|${INSTALL_HOME}|g" "$REPO_DIR/slideshow.sh" \
    > "${INSTALL_HOME}/slideshow.sh"
chmod +x "${INSTALL_HOME}/slideshow.sh"

chown "$INSTALL_USER:$INSTALL_USER" \
    "${INSTALL_HOME}/photo_bot.py" \
    "${INSTALL_HOME}/wifi_setup.py" \
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

# ── Self-update wrapper (for the bot's /reinstall command) ──────────────────

info "Installing self-update wrapper..."

# Bake an unauthenticated HTTPS fetch URL into the wrapper so /reinstall
# doesn't depend on SSH keys being available on the device. The repo is
# public, so HTTPS reads need no credentials.
ORIGIN_URL=$(sudo -u "$INSTALL_USER" git -C "$REPO_DIR" config --get remote.origin.url 2>/dev/null || true)
case "$ORIGIN_URL" in
    git@github.com:*)
        FETCH_URL="https://github.com/${ORIGIN_URL#git@github.com:}"
        ;;
    https://github.com/*)
        FETCH_URL="$ORIGIN_URL"
        ;;
    *)
        warn "Unknown origin URL '${ORIGIN_URL}' — /reinstall will use 'origin' as configured"
        FETCH_URL="origin"
        ;;
esac
info "  /reinstall fetch URL: ${FETCH_URL}"

cat > /usr/local/sbin/photoframe-reinstall <<EOF
#!/bin/bash
# Triggered by photoframe-reinstall.service. Fetches latest main from a
# fixed HTTPS URL (baked in at install time) so /reinstall never depends
# on SSH keys being present on the device.
set -e
cd "${REPO_DIR}"
runuser -u "${INSTALL_USER}" -- git fetch --quiet "${FETCH_URL}" main
runuser -u "${INSTALL_USER}" -- git reset --hard FETCH_HEAD
exec ./install.sh
EOF
chmod 0755 /usr/local/sbin/photoframe-reinstall

# Allow the bot user to kick off the reinstall service without a password.
# Pinned to the exact argv so this entry can only ever start that one unit.
cat > /etc/sudoers.d/photoframe-reinstall <<EOF
${INSTALL_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl start --no-block photoframe-reinstall.service
EOF
chmod 0440 /etc/sudoers.d/photoframe-reinstall

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
systemctl enable wifi_setup.service
systemctl enable wifi_watchdog.service
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
    if [ -t 0 ]; then
        read -rp "Reboot now? [y/N] " REBOOT
        if [[ "$REBOOT" =~ ^[Yy] ]]; then
            info "Rebooting..."
            reboot
        else
            echo "  Run 'sudo reboot' when ready."
        fi
    else
        # Non-interactive (e.g. triggered by /reinstall): the user has no
        # way to answer, and new boot params won't take effect until reboot.
        warn "Non-interactive — rebooting in 5s to apply boot params"
        sleep 5
        reboot
    fi
else
    # Use restart (not start) so re-installs pick up updated code.
    # On first install the services are inactive and restart behaves like start.
    info "Restarting services..."
    systemctl restart wifi_setup.service
    systemctl restart wifi_watchdog.service
    systemctl restart photo_bot.service
    systemctl restart slideshow.service
fi
