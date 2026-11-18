#!/bin/sh
# Chromium's sandbox helper runs setuid root.
chmod 4755 /usr/lib/iris-browser/chrome-sandbox 2>/dev/null || true
# Iris's apt repository moved to the GitHub releases (the packages carry
# Chromium now, too big for GitHub Pages): move the sources line over.
list=/etc/apt/sources.list.d/lite-go-browser.list
if [ -f "$list" ] && grep -q "tulip-labs.github.io/Lite-Go-Browser/deb" "$list"; then
	sed -i 's#https://tulip-labs.github.io/Lite-Go-Browser/deb stable main#https://github.com/Tulip-Labs/Iris-Browser/releases/latest download/#' "$list" || true
fi
# the project moved to Tulip-Labs/Iris-Browser: point the repository there
for f in /etc/yum.repos.d/lite-go-browser.repo /etc/zypp/repos.d/lite-go-browser.repo /etc/apt/sources.list.d/lite-go-browser.list; do
	[ -f "$f" ] && grep -q "Lite-Go-Browser" "$f" && sed -i 's#Lite-Go-Browser#Iris-Browser#g' "$f" || true
done
# the icon and the menu name change between versions: refresh the caches
touch /usr/share/icons/hicolor 2>/dev/null || true
command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor 2>/dev/null || true
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q /usr/share/applications 2>/dev/null || true
exit 0
