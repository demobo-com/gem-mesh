#!/usr/bin/env bash
# Headless emulator test bench on the 5090. Everything stays in the sandbox (~/mesh-android-sandbox);
# adb runs on port 5038 (set in env.sh) so the adb server on 5037 is never touched.
#
#   bench/emulator.sh setup            install emulator + x86_64 image, create the AVD
#   bench/emulator.sh start [window]   boot headless (or on the 5090's desktop), wait until ready
#   bench/emulator.sh install          install the debug APK, push E2B if missing, launch
#   bench/emulator.sh type "text"      type into the focused field
#   bench/emulator.sh ask "text"       type a message and press Send
#   bench/emulator.sh press "Label"    tap the element showing that text
#   bench/emulator.sh tap X Y          tap at screen coordinates
#   bench/emulator.sh shot [file]      screenshot (PNG)
#   bench/emulator.sh log [n]          last n lines of the app's log tags
#   bench/emulator.sh stop             shut the emulator down
set -euo pipefail
R=${MESH_SANDBOX:-$HOME/mesh-android-sandbox}
. "$R/env.sh"
AVD=mesh-bench
IMG="system-images;android-35;google_apis;x86_64"
PKG=com.demobo.mesh
SERIAL=emulator-5580
adb_() { adb -s $SERIAL "$@"; }

case "${1:-}" in
setup)
  sdkmanager --sdk_root="$ANDROID_HOME" "emulator" "$IMG" | tail -1
  mkdir -p "$ANDROID_AVD_HOME"
  echo no | avdmanager create avd -n $AVD -k "$IMG" -d pixel_7 --force
  cfg="$ANDROID_AVD_HOME/$AVD.avd/config.ini"
  sed -i '/^hw.ramSize/d;/^disk.dataPartition.size/d;/^hw.cpu.ncore/d;/^hw.keyboard/d' "$cfg"
  printf 'hw.ramSize=8192\ndisk.dataPartition.size=12G\nhw.cpu.ncore=8\nhw.keyboard=yes\n' >> "$cfg"
  ;;
start)  # `start window` shows the emulator on the 5090's desktop (X display :1); default is headless
  if [ "${2:-}" = window ]; then
    export DISPLAY=:1 XAUTHORITY=/run/user/$(id -u)/gdm/Xauthority; view=()
  else
    view=(-no-window)
  fi
  # Quick boot: restores the snapshot saved on the last clean shutdown (app and loaded model included).
  setsid nohup emulator -avd $AVD -ports 5580,5581 "${view[@]}" -no-audio -no-boot-anim \
    -gpu swiftshader_indirect > "$R/emulator.log" 2>&1 < /dev/null &
  adb_ wait-for-device
  until [ "$(adb_ shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; do sleep 3; done
  echo booted
  ;;
install)
  adb_ install -r "$R/src/app/build/outputs/apk/debug/app-debug.apk"
  # The 5090 already holds the same E2B file the app would download; push it instead.
  dir=/sdcard/Android/data/$PKG/files
  model=$HOME/.litert-lm/models/gemma4-e2b/model.litertlm
  if [ "$(adb_ shell stat -c %s $dir/gemma-4-E2B-it.litertlm 2>/dev/null | tr -d '\r')" != "$(stat -c %s "$model")" ]; then
    adb_ shell mkdir -p $dir
    adb_ push "$model" $dir/gemma-4-E2B-it.litertlm
  fi
  adb_ shell am force-stop $PKG
  adb_ shell am start -n $PKG/.MainActivity
  ;;
type) adb_ shell "input text '$(printf '%s' "$2" | sed "s/'//g; s/ /%s/g")'" ;;
ask)  # clear the message field, type, tap Send (found by the app's test tags "input" and "send")
  "$0" pressid input; sleep 1
  adb_ shell input keycombination 113 29; adb_ shell input keyevent 67   # Ctrl+A, Delete
  "$0" type "$2"; sleep 1
  "$0" pressid send ;;
pressid)  # tap the element whose test tag (resource-id) is "$2"
  b=$(adb_ exec-out uiautomator dump /dev/tty 2>/dev/null | grep -o "resource-id=\"$2\"[^>]*bounds=\"[^\"]*\"" | head -1 | grep -o 'bounds="[^"]*"')
  [ -n "$b" ] || { echo "no element with id \"$2\"" >&2; exit 1; }
  set -- $(echo "$b" | grep -oE '[0-9]+')
  adb_ shell input tap $(( ($1 + $3) / 2 )) $(( ($2 + $4) / 2 )) ;;
tap) adb_ shell input tap "$2" "$3" ;;
press)  # tap the on-screen element whose text is exactly "$2"
  b=$(adb_ exec-out uiautomator dump /dev/tty 2>/dev/null | grep -o "text=\"$2\"[^>]*bounds=\"[^\"]*\"" | head -1 | grep -o 'bounds="[^"]*"')
  [ -n "$b" ] || { echo "no element with text \"$2\"" >&2; exit 1; }
  set -- $(echo "$b" | grep -oE '[0-9]+')
  adb_ shell input tap $(( ($1 + $3) / 2 )) $(( ($2 + $4) / 2 )) ;;
shot) adb_ exec-out screencap -p > "${2:-$R/shot.png}" ;;
log) adb_ logcat -d -s MeshRouter LocalModel Classifier Discovery AndroidRuntime | tail -"${2:-50}" ;;
stop) adb_ emu kill ;;
*) sed -n '2,15p' "$0"; exit 1 ;;
esac
