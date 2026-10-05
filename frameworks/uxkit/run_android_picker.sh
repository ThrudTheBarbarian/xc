#!/bin/sh
# run_android_picker.sh — the `android-picker` gate: UXOpenPanel is the system document picker on the
# emulator.  The gate pushes a file to Downloads and plays the user for REAL through uiautomator: at
# the first picker it taps the file (going to Downloads first if it is not on the first screen), at
# the second it presses Back.  ANDROID_PICKER_SHOT=<png> screencaps the picker.  Skips cleanly
# without an emulator.
#
# The two-lib APK (see libUXAndroid.c's header), in one xcc line: the app lib is the pure xcc
# payload, its ux_and_* imports bound (--needed) against libUXAndroid.so, the NDK-built shim that
# Android loads first (--lib-name), which owns onCreate and delegates to the app lib's glue.  The
# bridge dex rides from tools/android/ (the committed bootstrap).
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
A="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="$A/platform-tools/adb"
NDKBIN=$(ls -d "$A"/ndk/*/toolchains/llvm/prebuilt/*/bin 2>/dev/null | sort -V | tail -1)
{ [ -n "$NDKBIN" ] && [ -x "$ADB" ]; } || { echo "== android-picker: skipped (no SDK/NDK) =="; exit 0; }
"$ADB" get-state >/dev/null 2>&1 || { echo "== android-picker: skipped (no device) =="; exit 0; }

# On the way out, stop the app: a task left behind is what Android goes back to when the next
# document-picker gate's picker closes, and the relaunched app's log lines land in that gate's.
work=$(mktemp -d); trap '"$ADB" shell am force-stop org.compile_xc.uxpicker >/dev/null 2>&1; rm -rf "$work"' EXIT
echo "== android-picker: the shim (NDK), then the APK in one xcc line =="
"$NDKBIN/aarch64-linux-android26-clang" -shared -fPIC -Wl,-soname,libUXAndroid.so \
    "$here/libUXAndroid.c" -llog -landroid -o "$work/libUXAndroid.so"
# --needed binds the app lib's ux_and_* imports against the shim; --lib-name
# makes the shim the library Android loads first; the bridge dex rides from tools/android/.
"$xcc" -A android --emit-apk -D TABLE_ANDROID -I "$here" "$here/test_picker_android.xc" \
    --needed libUXAndroid.so --with-lib "$work/libUXAndroid.so" --lib-name UXAndroid \
    --with-dex "$here/tools/android/classes.dex" -o "$work/uxpicker.apk" -q 2>/dev/null

echo "== android-picker: installing + launching =="
# A regenerated keystore signs with a new key, which Android refuses as an
# update of a package signed by the old one. Replace it rather than fail.
"$ADB" install -r "$work/uxpicker.apk" >/dev/null 2>&1 || {
    "$ADB" uninstall org.compile_xc.uxpicker >/dev/null 2>&1
    "$ADB" install "$work/uxpicker.apk" >/dev/null
}
"$ADB" logcat -c
"$ADB" shell am force-stop com.google.android.documentsui >/dev/null 2>&1 # a picker left from an earlier run
"$ADB" shell am start -S --activity-clear-task -n org.compile_xc.uxpicker/android.app.NativeActivity >/dev/null 2>&1
# Tap a view found on the live screen by its text or content-desc (uiautomator's dump).
tapon() {
  "$ADB" shell uiautomator dump /sdcard/ux.xml >/dev/null 2>&1
  b=$("$ADB" shell cat /sdcard/ux.xml | tr '>' '\n' | grep -E "(text|content-desc)=\"$1\"" | head -1 \
      | sed -n 's/.*bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]".*/\1 \2 \3 \4/p')
  [ -n "$b" ] || { echo "(no \"$1\" on screen)"; return 1; }
  set -- $b
  "$ADB" shell input tap $(( ($1 + $3) / 2 )) $(( ($2 + $4) / 2 ))
  sleep 1
}
printf 'picked on the device, h\303\251llo\n' > "$work/uxpick.txt"
"$ADB" push "$work/uxpick.txt" /sdcard/Download/uxpick.txt >/dev/null
"$ADB" shell content call --method scan_volume --uri content://media --arg external_primary >/dev/null 2>&1 || true
step=0
for i in $(seq 1 90); do
  out=$("$ADB" logcat -d -s xcapp uxkit)
  if [ $step = 0 ] && echo "$out" | grep -q PICK1; then
    step=1; sleep 3
    [ -n "$ANDROID_PICKER_SHOT" ] && "$ADB" exec-out screencap -p > "$ANDROID_PICKER_SHOT"
    tapon uxpick.txt || { tapon "Show roots" && tapon Downloads && tapon uxpick.txt; } || echo "(could not find the file in the picker)"
  fi
  if [ $step = 1 ] && echo "$out" | grep -q PICK2; then
    step=2; sleep 3
    "$ADB" shell input keyevent 4
  fi
  echo "$out" | grep -qE "PASS:|FAIL" && break
  sleep 1
done
"$ADB" shell rm -f /sdcard/Download/uxpick.txt
"$ADB" shell rm -f /sdcard/ux.xml # the screen dumps would show up in the device's recent files
echo "$out" | grep -v '^-' | grep -E 'ok |FAIL|PASS|picked:' | tail -20
echo "$out" | grep -q "PASS:" || { echo "== android-picker: FAILED =="; exit 1; }
echo "== android-picker: OK =="
