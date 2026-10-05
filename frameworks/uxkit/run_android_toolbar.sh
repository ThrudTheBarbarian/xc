#!/bin/sh
# run_android_toolbar.sh — the `android-toolbar` gate: UXToolbar is a real android.widget.Toolbar on
# the emulator.  Real input: the app logs the item it wants tapped (TAPTEXT <label>), and the gate
# finds that action on the live screen (uiautomator's dump, by text or description, any case) and taps
# it with adb input.  It reads only its own app's log, and stops the app on the way out.  Skips cleanly
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
{ [ -n "$NDKBIN" ] && [ -x "$ADB" ]; } || { echo "== android-toolbar: skipped (no SDK/NDK) =="; exit 0; }
"$ADB" get-state >/dev/null 2>&1 || { echo "== android-toolbar: skipped (no device) =="; exit 0; }

# On the way out, stop the app: a task left behind is what Android goes back to when the next
# document-picker gate's picker closes, and the relaunched app's log lines land in that gate's.
work=$(mktemp -d); trap '"$ADB" shell am force-stop org.compile_xc.uxtbar >/dev/null 2>&1; rm -rf "$work"' EXIT
echo "== android-toolbar: the shim (NDK), then the APK in one xcc line =="
"$NDKBIN/aarch64-linux-android26-clang" -shared -fPIC -Wl,-soname,libUXAndroid.so \
    "$here/libUXAndroid.c" -llog -landroid -o "$work/libUXAndroid.so"
# --needed binds the app lib's ux_and_* imports against the shim; --lib-name
# makes the shim the library Android loads first; the bridge dex rides from tools/android/.
"$xcc" -A android --emit-apk -I "$here" "$here/test_toolbar_android.xc" \
    --needed libUXAndroid.so --with-lib "$work/libUXAndroid.so" --lib-name UXAndroid \
    --with-dex "$here/tools/android/classes.dex" -o "$work/uxtbar.apk" -q 2>/dev/null

echo "== android-toolbar: installing + launching =="
# A regenerated keystore signs with a new key, which Android refuses as an
# update of a package signed by the old one. Replace it rather than fail.
"$ADB" install -r "$work/uxtbar.apk" >/dev/null 2>&1 || {
    "$ADB" uninstall org.compile_xc.uxtbar >/dev/null 2>&1
    "$ADB" install "$work/uxtbar.apk" >/dev/null
}
"$ADB" logcat -c
"$ADB" shell am start -S --activity-clear-task -n org.compile_xc.uxtbar/android.app.NativeActivity >/dev/null 2>&1
# Tap a view found on the live screen by its text or content-desc (uiautomator's dump), any case.
tapon() {
  "$ADB" shell uiautomator dump /sdcard/ux.xml >/dev/null 2>&1
  b=$("$ADB" shell cat /sdcard/ux.xml | tr '>' '\n' | grep -iE "(text|content-desc)=\"$1\"" | head -1 \
      | sed -n 's/.*bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]".*/\1 \2 \3 \4/p')
  [ -n "$b" ] || { echo "(no \"$1\" on screen)"; return 1; }
  set -- $b
  "$ADB" shell input tap $(( ($1 + $3) / 2 )) $(( ($2 + $4) / 2 ))
}
tapped=
for i in $(seq 1 90); do
  pid=$("$ADB" shell pidof org.compile_xc.uxtbar 2>/dev/null | tr -d '\r')
  [ -n "$pid" ] && out=$("$ADB" logcat -d --pid="$pid" -s xcapp uxkit)
  for label in $(echo "$out" | sed -n 's/.*TAPTEXT \([A-Za-z]*\).*/\1/p'); do
    case " $tapped " in *" $label "*) continue ;; esac
    sleep 1
    tapon "$label" || true
    tapped="$tapped $label"
  done
  echo "$out" | grep -qE "PASS:|FAIL:" && break
  sleep 1
done
"$ADB" shell rm -f /sdcard/ux.xml # the screen dumps would show up in the device's recent files
echo "$out" | grep -v '^-' | grep -E 'ok |FAIL|PASS|TAPTEXT' | sed 's/^.*xcapp *: //' | tail -20
echo "$out" | grep -q "PASS:" || { echo "== android-toolbar: FAILED =="; exit 1; }
echo "== android-toolbar: OK =="
