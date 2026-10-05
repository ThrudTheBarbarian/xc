#!/bin/sh
# run_android_gl.sh — the `android-gl` gate: GL on Android through the neutral seam (GLES 3,
# rendered offscreen, its frame painted in the window's 2-D pass with 2-D views over it) on the
# emulator.  Skips cleanly without one.
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
{ [ -n "$NDKBIN" ] && [ -x "$ADB" ]; } || { echo "== android-gl: skipped (no SDK/NDK) =="; exit 0; }
"$ADB" get-state >/dev/null 2>&1 || { echo "== android-gl: skipped (no device) =="; exit 0; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== android-gl: the shim (NDK), then the APK in one xcc line =="
"$NDKBIN/aarch64-linux-android26-clang" -shared -fPIC -Wl,-soname,libUXAndroid.so \
    "$here/libUXAndroid.c" -llog -landroid -o "$work/libUXAndroid.so"
# --needed binds the app lib's ux_and_* imports against the shim; --lib-name
# makes the shim the library Android loads first; the bridge dex rides from tools/android/.
"$xcc" -A android --emit-apk -I "$here" "$here/test_android_gl.xc" \
    --needed libUXAndroid.so --with-lib "$work/libUXAndroid.so" --lib-name UXAndroid \
    --with-dex "$here/tools/android/classes.dex" -o "$work/uxgl.apk" -q 2>/dev/null

echo "== android-gl: installing + launching =="
# A regenerated keystore signs with a new key, which Android refuses as an
# update of a package signed by the old one. Replace it rather than fail.
"$ADB" install -r "$work/uxgl.apk" >/dev/null 2>&1 || {
    "$ADB" uninstall org.compile_xc.uxgl >/dev/null 2>&1
    "$ADB" install "$work/uxgl.apk" >/dev/null
}
"$ADB" logcat -c
"$ADB" shell am start -S --activity-clear-task -n org.compile_xc.uxgl/android.app.NativeActivity >/dev/null 2>&1
for i in $(seq 1 40); do
  out=$("$ADB" logcat -d -s xcapp uxkit)
  echo "$out" | grep -qE "PASS:|FAIL" && break
  sleep 1
done
echo "$out" | grep -v '^-' | sed 's/^.*xcapp *: //' | grep -E 'ok |FAIL|PASS|\(' | tail -24
[ -n "$ANDROID_GL_SHOT" ] && "$ADB" exec-out screencap -p > "$ANDROID_GL_SHOT"
echo "$out" | grep -q "PASS:" || { echo "== android-gl: FAILED =="; exit 1; }
echo "== android-gl: OK =="
