#!/bin/bash
set -e

INSTALL_USER="${SUDO_USER:-$USER}"
INSTALL_HOME="$(eval echo ~"$INSTALL_USER")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[✗]${NC} Run with sudo: sudo ./uninstall.sh"; exit 1
fi

info "Stopping services..."
systemctl stop photo_bot.service 2>/dev/null || true
systemctl stop slideshow.service 2>/dev/null || true
systemctl stop wifi_setup.service 2>/dev/null || true
systemctl stop wifi_watchdog.service 2>/dev/null || true
systemctl disable photo_bot.service 2>/dev/null || true
systemctl disable slideshow.service 2>/dev/null || true
systemctl disable wifi_setup.service 2>/dev/null || true
systemctl disable wifi_watchdog.service 2>/dev/null || true

info "Removing service files..."
rm -f /etc/systemd/system/photo_bot.service
rm -f /etc/systemd/system/slideshow.service
rm -f /etc/systemd/system/wifi_setup.service
rm -f /etc/systemd/system/wifi_watchdog.service
systemctl daemon-reload

info "Removing application files..."
rm -f "${INSTALL_HOME}/photo_bot.py"
rm -f "${INSTALL_HOME}/wifi_setup.py"
rm -f "${INSTALL_HOME}/slideshow.sh"
rm -rf "${INSTALL_HOME}/photos_rotated"

echo ""
info "Uninstall complete."
echo ""
warn "Kept (delete manually if desired):"
echo "  ${INSTALL_HOME}/photos/                (your photos)"
echo "  ${INSTALL_HOME}/photo_bot.log          (bot log)"
echo "  ${INSTALL_HOME}/.photo_bot_state.json  (bot state)"
echo "  ${INSTALL_HOME}/.photo_bot_config.json (config)"
