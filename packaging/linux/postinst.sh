#!/bin/sh
# Chromium's sandbox helper runs setuid root.
chmod 4755 /usr/lib/lite-go-browser/chrome-sandbox 2>/dev/null || true
