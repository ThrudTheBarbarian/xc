#!/bin/sh
# make android-settings — UXKeyValueStore over REAL SharedPreferences, written
# by one launch, read by the next.  `pm clear` empties the app's data first,
# so the pair is hermetic and the pass marker self-sequences the two launches.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
A="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="$A/platform-tools/adb"
NDKBIN=$(ls -d "$A"/ndk/*/toolchains/llvm/prebuilt/*/bin 2>/dev/null | sort -V | tail -1)
{ [ -n "$NDKBIN" ] && [ -x "$ADB" ]; } || { echo "== android-settings: skipped (no SDK/NDK) =="; exit 0; }
"$ADB" get-state >/dev/null 2>&1 || { echo "== android-settings: skipped (no device) =="; exit 0; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== android-settings: the shim (NDK), then the APK in one xcc line =="
"$NDKBIN/aarch64-linux-android26-clang" -shared -fPIC -Wl,-soname,libUXAndroid.so \
    "$here/libUXAndroid.c" -llog -landroid -o "$work/libUXAndroid.so"
"$xcc" -A android --emit-apk -I "$here" "$here/test_android_settings.xc" \
    --needed libUXAndroid.so --with-lib "$work/libUXAndroid.so" --lib-name UXAndroid \
    --with-dex "$here/tools/android/classes.dex" -o "$work/uxset.apk" -q 2>/dev/null

# A regenerated keystore signs with a new key, which Android refuses as an
# update of a package signed by the old one. Replace it rather than fail.
"$ADB" install -r "$work/uxset.apk" >/dev/null 2>&1 || {
    "$ADB" uninstall org.compile_xc.uxset >/dev/null 2>&1
    "$ADB" install "$work/uxset.apk" >/dev/null
}
"$ADB" shell pm clear org.compile_xc.uxset >/dev/null

echo "== android-settings: launch 1 (write) =="
"$ADB" logcat -c
"$ADB" shell am start -S --activity-clear-task -n org.compile_xc.uxset/android.app.NativeActivity >/dev/null 2>&1
sleep 5
"$ADB" logcat -d -s xcapp | grep -q "WROTE: first launch complete" || {
    echo "== android-settings: FAILED (write pass) =="; "$ADB" logcat -d -s xcapp uxkit | tail -8; exit 1; }
"$ADB" logcat -d -s xcapp | grep -v '^-' | sed 's/.*xcapp   ://;s/^/ /'

echo "== android-settings: launch 2 (a fresh process reads it back) =="
"$ADB" logcat -c
"$ADB" shell am start -S --activity-clear-task -n org.compile_xc.uxset/android.app.NativeActivity >/dev/null 2>&1
sleep 5
out=$("$ADB" logcat -d -s xcapp | grep -v '^-' | sed 's/.*xcapp   ://')
printf '%s\n' "$out"
if printf '%s\n' "$out" | grep -q "PASS: settings persist in SharedPreferences"; then
    echo "== android-settings: PASS — preferences live in SharedPreferences =="
else
    echo "== android-settings: FAIL =="; exit 1
fi
