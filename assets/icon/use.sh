#!/bin/sh
# Puts one of Iris's icons in every place Iris uses it:
#   assets/icon/use.sh spectrum the ring on Iris's website: clear glass, the spectrum gathered at its
#                               lower rim, on a near-colourless tile (the default, 2.3 and newer)
#   assets/icon/use.sh ring     a clear glass ring on a white tile, light in and a rainbow out (2.2.0 and newer)
#   assets/icon/use.sh glass    her profile, her hair in sheets of liquid glass
#   assets/icon/use.sh night    the goddess on Iris's night (deep indigo, a glowing rainbow)
#   assets/icon/use.sh day      the goddess on Iris's day (pearl, pink and sky)
# (the wallpaper's gen.js draws Iris from variants/day/iris.svg)
set -eu
cd "$(dirname "$0")/../.."
v=${1:-}
[ "$v" = spectrum ] || [ "$v" = ring ] || [ "$v" = glass ] || [ "$v" = night ] || [ "$v" = day ] || { echo "usage: $0 spectrum|ring|glass|night|day" >&2; exit 2; }
src=assets/icon/variants/$v
cp "$src/iris.svg" "$src/iris-fullbleed.svg" assets/icon/
for n in 48 64 128 256 512; do cp "$src/iris-$n.png" assets/icon/; done
cp "$src/iris.svg" linux/resources/icons/hicolor/scalable/apps/io.github.tulip_labs.Iris.svg
cp "$src/iris-256.png" linux/resources/icons/hicolor/256x256/apps/io.github.tulip_labs.Iris.png
for d in mdpi hdpi xhdpi xxhdpi xxxhdpi; do
	cp "$src/android/mipmap-$d/ic_launcher.png" "$src/android/mipmap-$d/ic_launcher_foreground.png" android/app/src/main/res/mipmap-$d/
done
# themed icons (Android 13+): a one-colour drawing, if the variant has one
res=android/app/src/main/res
if [ -f "$src/android/drawable/ic_launcher_monochrome.xml" ]; then
	cp "$src/android/drawable/ic_launcher_monochrome.xml" $res/drawable/
	grep -q '<monochrome' $res/mipmap-anydpi-v26/ic_launcher.xml ||
		sed -i 's|^\(.*\)<foreground \(.*\)$|\1<foreground \2\n\1<monochrome android:drawable="@drawable/ic_launcher_monochrome" />|' $res/mipmap-anydpi-v26/ic_launcher.xml
else
	rm -f $res/drawable/ic_launcher_monochrome.xml
	sed -i '/<monochrome /d' $res/mipmap-anydpi-v26/ic_launcher.xml
fi
# the colour behind the adaptive icon while a launcher draws it
case $v in spectrum) back="#F2F3F5" ;; night) back="#1D1450" ;; glass) back="#F3F2FC" ;; ring) back="#F0EFEB" ;; *) back="#F6E6F4" ;; esac
sed -i "s|<color name=\"icon_back\">.*</color>|<color name=\"icon_back\">$back</color>|" android/app/src/main/res/values/colors.xml
echo "The $v icon is in place."
