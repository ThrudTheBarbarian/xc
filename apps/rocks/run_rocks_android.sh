#!/bin/sh
# run_rocks_android.sh — the `rocks-android` gate: Rocks, unchanged but for RKDriver's RK_ANDROID
# branch, on the emulator.  Builds the two-lib APK the UXKit Android gates build (libxtapp.so from
# xcc, the NDK-built shim, the bridge dex), launches it, waits for its window-up line, and checks the
# window is really on screen: a screencap must hold the editor's canvas, its blue grid.
# ROCKS_ANDROID_SHOT=<png> keeps the screencap.  Skips cleanly without an emulator.
#
# The two-lib APK (see libUXAndroid.c's header), in one xcc line: the app lib is the pure xcc
# payload, its ux_and_* imports bound (--needed) against libUXAndroid.so, the NDK-built shim that
# Android loads first (--lib-name), which owns onCreate and delegates to the app lib's glue.  The
# bridge dex rides from tools/android/ (the committed bootstrap); --manifest-attr names the app and
# takes the back gesture.
set -e
here=$(cd "$(dirname "$0")" && pwd)
ux="$here/../../frameworks/uxkit"
xcc=${XCC:-xcc}
A="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="$A/platform-tools/adb"
NDKBIN=$(ls -d "$A"/ndk/*/toolchains/llvm/prebuilt/*/bin 2>/dev/null | sort -V | tail -1)
{ [ -n "$NDKBIN" ] && [ -x "$ADB" ]; } || { echo "== rocks-android: skipped (no SDK/NDK) =="; exit 0; }
"$ADB" get-state >/dev/null 2>&1 || { echo "== rocks-android: skipped (no device) =="; exit 0; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== rocks-android: the shim (NDK), then the APK in one xcc line =="
"$NDKBIN/aarch64-linux-android26-clang" -shared -fPIC -Wl,-soname,libUXAndroid.so \
    "$ux/libUXAndroid.c" -llog -landroid -o "$work/libUXAndroid.so"
"$xcc" -A android --emit-apk -D RK_ANDROID -I "$ux" -I "$here/xc" "$here/xc/rocks_main.xc" \
    --needed libUXAndroid.so --with-lib "$work/libUXAndroid.so" --lib-name UXAndroid \
    --with-dex "$ux/tools/android/classes.dex" \
    --manifest-attr label=Rocks --manifest-attr enableOnBackInvokedCallback=true \
    -o "$work/rocks.apk" -q

echo "== rocks-android: installing + launching =="
# A regenerated keystore signs with a new key, which Android refuses as an
# update of a package signed by the old one. Replace it rather than fail.
"$ADB" install -r "$work/rocks.apk" >/dev/null 2>&1 || {
    "$ADB" uninstall org.compile_xc.rocks >/dev/null 2>&1
    "$ADB" install "$work/rocks.apk" >/dev/null
}
"$ADB" logcat -c
"$ADB" shell am start -S --activity-clear-task -n org.compile_xc.rocks/android.app.NativeActivity >/dev/null 2>&1
for i in $(seq 1 40); do
  out=$("$ADB" logcat -d -s xcapp uxkit)
  echo "$out" | grep -qE "PASS:|FAIL|SKIP:" && break
  sleep 1
done
sleep 2
shot=${ROCKS_ANDROID_SHOT:-$work/shot.png}
"$ADB" exec-out screencap -p > "$shot"
"$ADB" shell am force-stop org.compile_xc.rocks
echo "$out" | grep -E "PASS:|FAIL|SKIP:" | sed 's/.*xcapp *: //' | head -2
echo "$out" | grep -q "PASS:" || { echo "$out" | tail -15; echo "== rocks-android: FAILED =="; exit 1; }
# on screen: the canvas pane (the middle of the editor) shows the editor's blue grid -- blue well
# above red, which a blank white or black launch screen is not
px=$(magick "$shot" -gravity center -crop 1x1+0+0 -format '%[fx:int(255*r)],%[fx:int(255*g)],%[fx:int(255*b)]' info: 2>/dev/null || echo "?")
echo "screen centre pixel: $px"
r=${px%%,*}; b=${px##*,}
{ [ "$px" != "?" ] && [ $((b - r)) -ge 15 ] && [ "$b" -ge 200 ]; } || { echo "== rocks-android: FAILED (the editor is not on screen) =="; exit 1; }
echo "== rocks-android: OK — Rocks runs on Android =="
