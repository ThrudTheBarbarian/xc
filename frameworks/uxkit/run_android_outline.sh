#!/bin/sh
# run_android_outline.sh — the `android-outline` gate: UXOutlineView realized as the native ListView on the
# emulator: flattened rows, an arrow that opens an item (tapped for REAL), indent, selection by item.  ANDROID_OUTLINE_SHOT=<png> also screencaps it.
# Skips cleanly without an emulator.
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
{ [ -n "$NDKBIN" ] && [ -x "$ADB" ]; } || { echo "== android-outline: skipped (no SDK/NDK) =="; exit 0; }
"$ADB" get-state >/dev/null 2>&1 || { echo "== android-outline: skipped (no device) =="; exit 0; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== android-outline: the shim (NDK), then the APK in one xcc line =="
"$NDKBIN/aarch64-linux-android26-clang" -shared -fPIC -Wl,-soname,libUXAndroid.so \
    "$here/libUXAndroid.c" -llog -landroid -o "$work/libUXAndroid.so"
# --needed binds the app lib's ux_and_* imports against the shim; --lib-name
# makes the shim the library Android loads first; the bridge dex rides from tools/android/.
"$xcc" -A android --emit-apk -D TABLE_ANDROID -I "$here" "$here/test_outline_native.xc" \
    --needed libUXAndroid.so --with-lib "$work/libUXAndroid.so" --lib-name UXAndroid \
    --with-dex "$here/tools/android/classes.dex" -o "$work/uxoutline.apk" -q 2>/dev/null

echo "== android-outline: installing + launching =="
# A regenerated keystore signs with a new key, which Android refuses as an
# update of a package signed by the old one. Replace it rather than fail.
"$ADB" install -r "$work/uxoutline.apk" >/dev/null 2>&1 || {
    "$ADB" uninstall org.compile_xc.uxoutline >/dev/null 2>&1
    "$ADB" install "$work/uxoutline.apk" >/dev/null
}
"$ADB" logcat -c
"$ADB" shell am start -S --activity-clear-task -n org.compile_xc.uxoutline/android.app.NativeActivity >/dev/null 2>&1
# The test logs where its first row is on screen; tap it there for REAL (the OS's own input path,
# not a call into the list), then wait for the verdict.
tapped=0
for i in $(seq 1 40); do
  out=$("$ADB" logcat -d -s xcapp uxkit)
  if [ $tapped = 0 ]; then
    at=$(echo "$out" | sed -n 's/.*TAPAT \([0-9-]*\) \([0-9-]*\).*/\1 \2/p' | tail -1)
    [ -n "$at" ] && { "$ADB" shell input tap $at; tapped=1; }
  fi
  echo "$out" | grep -qE "PASS:|FAIL" && break
  sleep 1
done
echo "$out" | grep -v '^-' | tail -20
[ -n "$ANDROID_OUTLINE_SHOT" ] && "$ADB" exec-out screencap -p > "$ANDROID_OUTLINE_SHOT"
echo "$out" | grep -q "PASS:" || { echo "== android-outline: FAILED =="; exit 1; }
echo "== android-outline: OK =="
