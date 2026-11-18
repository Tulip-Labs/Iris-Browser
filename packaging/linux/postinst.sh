#!/bin/sh
# Chromium's sandbox helper runs setuid root.
chmod 4755 /usr/lib/iris-browser/chrome-sandbox 2>/dev/null || true
# the project moved to Tulip-Labs/Iris-Browser: point the repository there
for f in /etc/yum.repos.d/lite-go-browser.repo /etc/zypp/repos.d/lite-go-browser.repo /etc/apt/sources.list.d/lite-go-browser.list; do
	[ -f "$f" ] && grep -q "Lite-Go-Browser" "$f" && sed -i 's#Lite-Go-Browser#Iris-Browser#g' "$f" || true
done
# the icon and the menu name change between versions: refresh the caches
touch /usr/share/icons/hicolor 2>/dev/null || true
command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor 2>/dev/null || true
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q /usr/share/applications 2>/dev/null || true
