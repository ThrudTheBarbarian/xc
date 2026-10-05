#!/bin/sh
# run_android_real.sh — the Android driver's bring-up gate (`android-alert`):
# the neutral UXKit layer running native on the emulator, unattended.  Skips
# cleanly when the SDK or a device is absent.
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
{ [ -n "$NDKBIN" ] && [ -x "$ADB" ]; } || { echo "== android-alert: skipped (no SDK/NDK) =="; exit 0; }
"$ADB" get-state >/dev/null 2>&1 || { echo "== android-alert: skipped (no device) =="; exit 0; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== android-alert: the shim (NDK), then the APK in one xcc line =="
"$NDKBIN/aarch64-linux-android26-clang" -shared -fPIC -Wl,-soname,libUXAndroid.so \
    "$here/libUXAndroid.c" -llog -landroid -o "$work/libUXAndroid.so"
# --needed binds the app lib's ux_and_* imports against the shim; --lib-name
# makes the shim the library Android loads first; the bridge dex rides from tools/android/.
"$xcc" -A android --emit-apk -I "$here" "$here/test_android_alert.xc" \
    --needed libUXAndroid.so --with-lib "$work/libUXAndroid.so" --lib-name UXAndroid \
    --with-dex "$here/tools/android/classes.dex" -o "$work/uxalert.apk" -q 2>/dev/null

echo "== android-alert: installing + launching =="
# A regenerated keystore signs with a new key, which Android refuses as an
# update of a package signed by the old one. Replace it rather than fail.
"$ADB" install -r "$work/uxalert.apk" >/dev/null 2>&1 || {
    "$ADB" uninstall org.compile_xc.uxalert >/dev/null 2>&1
    "$ADB" install "$work/uxalert.apk" >/dev/null
}
"$ADB" logcat -c
"$ADB" shell am start -S --activity-clear-task -n org.compile_xc.uxalert/android.app.NativeActivity >/dev/null 2>&1
sleep 6
out=$("$ADB" logcat -d -s xcapp uxkit)
echo "$out" | grep -v '^-' | tail -20
echo "$out" | grep -q "PASS:" || { echo "== android-alert: FAILED =="; exit 1; }
echo "== android-alert: OK =="
