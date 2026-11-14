#!/usr/bin/env bash
# Screenshots of Lite for Android in the emulator (see .github/workflows/android-screens.yml).
set -x
mkdir -p screens
P=org.tulipanlabs.lite
adb install -r android/app/build/outputs/apk/debug/*.apk
start() { adb shell am start -n $P/.MainActivity "$@" >/dev/null; }
shot() { sleep "${2:-4}"; adb exec-out screencap -p > "screens/$1.png"; }
back() { adb shell input keyevent KEYCODE_BACK; sleep 1; }

start; sleep 12; adb shell am force-stop $P; start; shot start 10
for th in crocus peach mint night; do
  start --es lite.theme $th --es lite.open menu; shot menu-$th
  adb shell input swipe 540 1800 540 600 300; shot menu-$th-2 2
  back
done
start --es lite.theme crocus --es lite.open tabs; shot tabs; back
start --es lite.open new; shot new-menu; back
start --es lite.open shield; shot shield; back
start --es lite.mode web --es lite.url "red\ pandas"; shot results 16
adb shell input swipe 540 1800 540 700 300; shot results-2 2

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
start --es lite.mode web --es lite.url "red\ pandas"; shot tablet-results 16
adb shell wm size reset
adb shell wm density reset
adb logcat -d -b crash > screens/crash.txt
adb logcat -d -s AndroidRuntime:E chromium:E LiteResults:I > screens/errors.txt
ls -la screens
