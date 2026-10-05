#!/bin/sh
# run_android_snapshot.sh — the `android-snapshot` gate: UXWindow.snapshot on the emulator: the GL
# frame (GLES 3, painted in the 2-D pass), the 2-D views over it and a native Button, whole or a
# region.  It reads only its own app's log, and stops the app on the way out.  Skips cleanly without
# an emulator.
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
{ [ -n "$NDKBIN" ] && [ -x "$ADB" ]; } || { echo "== android-snapshot: skipped (no SDK/NDK) =="; exit 0; }
"$ADB" get-state >/dev/null 2>&1 || { echo "== android-snapshot: skipped (no device) =="; exit 0; }

work=$(mktemp -d); trap '"$ADB" shell am force-stop org.compile_xc.uxsnap >/dev/null 2>&1; rm -rf "$work"' EXIT
echo "== android-snapshot: the shim (NDK), then the APK in one xcc line =="
"$NDKBIN/aarch64-linux-android26-clang" -shared -fPIC -Wl,-soname,libUXAndroid.so \
    "$here/libUXAndroid.c" -llog -landroid -o "$work/libUXAndroid.so"
# --needed binds the app lib's ux_and_* imports against the shim; --lib-name
# makes the shim the library Android loads first; the bridge dex rides from tools/android/.
"$xcc" -A android --emit-apk -I "$here" -D SNAP_ANDROID "$here/test_snapshot.xc" \
    --needed libUXAndroid.so --with-lib "$work/libUXAndroid.so" --lib-name UXAndroid \
    --with-dex "$here/tools/android/classes.dex" -o "$work/uxsnap.apk" -q 2>/dev/null

echo "== android-snapshot: installing + launching =="
# A regenerated keystore signs with a new key, which Android refuses as an
# update of a package signed by the old one. Replace it rather than fail.
"$ADB" install -r "$work/uxsnap.apk" >/dev/null 2>&1 || {
    "$ADB" uninstall org.compile_xc.uxsnap >/dev/null 2>&1
    "$ADB" install "$work/uxsnap.apk" >/dev/null
}
"$ADB" logcat -c
"$ADB" shell am start -S --activity-clear-task -n org.compile_xc.uxsnap/android.app.NativeActivity >/dev/null 2>&1
for i in $(seq 1 40); do
  pid=$("$ADB" shell pidof org.compile_xc.uxsnap 2>/dev/null | tr -d '\r')
  [ -n "$pid" ] && out=$("$ADB" logcat -d --pid="$pid" -s xcapp uxkit)
  echo "$out" | grep -qE "PASS:|FAIL" && break
  sleep 1
done
echo "$out" | grep -v '^-' | sed 's/^.*xcapp *: //' | grep -E 'ok |FAIL|PASS|\(' | tail -24
[ -n "$ANDROID_GL_SHOT" ] && "$ADB" exec-out screencap -p > "$ANDROID_GL_SHOT"
echo "$out" | grep -q "PASS:" || { echo "== android-snapshot: FAILED =="; exit 1; }
echo "== android-snapshot: OK =="
