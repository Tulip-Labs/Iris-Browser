#!/usr/bin/env bash
# Screenshots of Iris for Android in the emulator (see .github/workflows/android-screens.yml).
set -x
mkdir -p screens
P=org.tulipanlabs.lite
adb install -r android/app/build/outputs/apk/debug/*.apk
# the emulator's own launcher stalls under software drawing: no "isn't responding" dialogs over the shots
adb shell settings put global hide_error_dialogs 1
adb shell settings put secure anr_show_background 0
start() { adb shell am start -n $P/.MainActivity "$@" >/dev/null; }
shot() { sleep "${2:-4}"; adb shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS >/dev/null 2>&1; sleep 0.5; adb exec-out screencap -p > "screens/$1.png"; }
visit() { adb shell am start -a android.intent.action.VIEW -d "$1" -n $P/.MainActivity >/dev/null; }
back() { adb shell input keyevent KEYCODE_BACK; sleep 1; }

start; sleep 12; adb shell am force-stop $P; start; shot start 10
# the desktop's backgrounds under the same glass
for th in sky dawn meadow lilac; do
  start --es lite.theme $th --es lite.open menu; shot menu-$th
  adb shell input swipe 540 1800 540 600 300; shot menu-$th-2 2
  back
done
start --es lite.theme sky --es lite.open tabs; shot tabs; back
# several tabs in the strip on top, as on the desktop
visit https://en.wikipedia.org/wiki/Iris_(mythology); sleep 6
visit https://www.gnu.org/; sleep 6
visit https://example.com/; shot tab-strip 8
start --es lite.open new; shot new-menu; back
start --es lite.open shield; shot shield; back
# a search: Google AI Mode
start --es lite.url "red\ pandas"; shot search-ai 16
# real sites on the bundled Chromium
visit https://en.wikipedia.org/wiki/Red_panda; shot page-wikipedia 12
visit https://www.youtube.com/; shot page-youtube 14
visit https://github.com/Tulip-Labs/Iris-Browser; shot page-github 12

# landscape and a tablet
adb shell settings put system accelerometer_rotation 0
adb shell settings put system user_rotation 1
start; shot landscape 5
start --es lite.open menu; shot landscape-menu; back
adb shell settings put system user_rotation 0
adb shell wm size 1600x2560
adb shell wm density 320
sleep 3
start; shot tablet 6
start --es lite.open tabs; shot tablet-tabs; back
start --es lite.open menu; shot tablet-menu; back
start --es lite.url "red\ pandas"; shot tablet-search-ai 16
adb shell wm size reset
adb shell wm density reset
adb logcat -d -b crash > screens/crash.txt
adb logcat -d -s AndroidRuntime:E chromium:E cefrium:* Cefrium:* > screens/errors.txt
ls -la screens
