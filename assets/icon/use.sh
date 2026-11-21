#!/bin/sh
# Puts one of the two icons in every place Iris uses it:
#   assets/icon/use.sh night    the goddess on Iris's night (deep indigo, a glowing rainbow)
#   assets/icon/use.sh day      the goddess on Iris's day (pearl, pink and sky)
set -eu
cd "$(dirname "$0")/../.."
v=${1:-}
[ "$v" = night ] || [ "$v" = day ] || { echo "usage: $0 night|day" >&2; exit 2; }
src=assets/icon/variants/$v
cp "$src/iris.svg" "$src/iris-fullbleed.svg" assets/icon/
for n in 48 64 128 256 512; do cp "$src/iris-$n.png" assets/icon/; done
cp "$src/iris.svg" linux/Sources/Iris/Resources/icons/hicolor/scalable/apps/io.github.tulip_labs.Iris.svg
cp "$src/iris-256.png" linux/Sources/Iris/Resources/icons/hicolor/256x256/apps/io.github.tulip_labs.Iris.png
for d in mdpi hdpi xhdpi xxhdpi xxxhdpi; do
	cp "$src/android/mipmap-$d/ic_launcher.png" "$src/android/mipmap-$d/ic_launcher_foreground.png" android/app/src/main/res/mipmap-$d/
done
# the colour behind the adaptive icon while a launcher draws it
if [ "$v" = night ]; then back="#1D1450"; else back="#F6E6F4"; fi
sed -i "s|<color name=\"icon_back\">.*</color>|<color name=\"icon_back\">$back</color>|" android/app/src/main/res/values/colors.xml
echo "The $v icon is in place."
