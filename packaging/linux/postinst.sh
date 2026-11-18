#!/bin/sh
# Chromium's sandbox helper runs setuid root.
chmod 4755 /usr/lib/lite-go-browser/chrome-sandbox 2>/dev/null || true
# the icon and the menu name change between versions: refresh the caches
touch /usr/share/icons/hicolor 2>/dev/null || true
command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor 2>/dev/null || true
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q /usr/share/applications 2>/dev/null || true
