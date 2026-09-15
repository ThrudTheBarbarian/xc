#!/bin/sh
# run.sh — the bridge-dex spike gate: repack, install, launch, grep logcat.
set -e
here=$(cd "$(dirname "$0")" && pwd)
A="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
BT="$A/build-tools/36.0.0"; ADB="$A/platform-tools/adb"
NDK="$A/ndk/27.0.12077973/toolchains/llvm/prebuilt/darwin-x86_64/bin"
{ [ -x "$ADB" ] && "$ADB" get-state >/dev/null 2>&1; } || { echo "== android-bridge: skipped (no device) =="; exit 0; }
cd "$here"
"$NDK/aarch64-linux-android35-clang" -shared -fPIC bridge_spike.c -llog -landroid -o /tmp/libbase.so
"$BT/aapt2" link -I "$A/platforms/android-35/android.jar" --manifest AndroidManifest.xml -o /tmp/ux-mo.apk
rm -rf /tmp/ux-pack && mkdir -p /tmp/ux-pack/lib/arm64-v8a
cp classes.dex /tmp/ux-pack/ && cp /tmp/libbase.so /tmp/ux-pack/lib/arm64-v8a/libbase.so
cp /tmp/ux-mo.apk /tmp/ux-un.apk
( cd /tmp/ux-pack && zip -q /tmp/ux-un.apk classes.dex lib/arm64-v8a/libbase.so )
"$BT/zipalign" -f 4 /tmp/ux-un.apk /tmp/ux-al.apk
[ -f "$here/debug.keystore" ] || keytool -genkeypair -keystore "$here/debug.keystore" -storepass uxspike -alias ux -dname "CN=uxspike" -keyalg RSA -validity 10000 2>/dev/null
"$BT/apksigner" sign --ks "$here/debug.keystore" --ks-pass pass:uxspike --out /tmp/ux-spike.apk /tmp/ux-al.apk 2>/dev/null
"$ADB" install -r /tmp/ux-spike.apk >/dev/null
"$ADB" logcat -c
"$ADB" shell am start -n org.compile_xc.uxspike/android.app.NativeActivity >/dev/null 2>&1
sleep 3
out=$("$ADB" logcat -d -s UXSPIKE)
echo "$out" | tail -6
echo "$out" | grep -q "PASS: bridge fired" || { echo "== android-bridge: FAILED =="; exit 1; }
echo "== android-bridge: OK =="
