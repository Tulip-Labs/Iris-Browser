#!/bin/sh
# Points the Chromium (CEF) Flatpak at a CEF binary distribution built with
# proprietary codecs (H.264, H.265, AAC): see packaging/codecs.md.
#   sh packaging/flatpak/use-codecs.sh URL SHA256 [MANIFEST]
set -eu
[ $# -ge 2 ] || { echo "usage: $0 URL SHA256 [MANIFEST]" >&2; exit 2; }
f=${3:-$(dirname "$0")/io.github.tulip_labs.Iris.Cef.yml}
python3 - "$f" "$1" "$2" <<'PY'
import re, sys
f, url, sha = sys.argv[1:4]
if not re.fullmatch(r"[0-9a-f]{64}", sha): sys.exit("SHA256 is 64 lowercase hex digits")
if not url.startswith("https://"): sys.exit("the URL must be https")
s = open(f).read()
s, n = re.subn(r"(url: )https://\S*cef_binary_\S*(\n(?: *#.*\n)*? *sha256: )[0-9a-f]{64}", lambda m: m.group(1) + url + m.group(2) + sha, s, count=1)
if n != 1: sys.exit("the CEF source was not found in " + f)
open(f, "w").write(s)
print("CEF now from", url)
PY
