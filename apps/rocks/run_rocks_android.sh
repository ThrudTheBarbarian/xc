#!/bin/sh
# run_rocks_android.sh — the `rocks-android` gate: Rocks, unchanged but for RKDriver's RK_ANDROID
# branch, on the emulator.  Builds the two-lib APK the UXKit Android gates build (libxtapp.so from
# xcc, the NDK-built shim, the bridge dex), launches it, waits for its window-up line, and checks the
# window is really on screen: a screencap must hold the editor's white canvas pane.
# ROCKS_ANDROID_SHOT=<png> keeps the screencap.  Skips cleanly without an emulator.
#
# The two-lib APK (see libUXAndroid.c's header): libxtapp.so is the PURE xcc
# artifact (`xcc -A android --emit-apk`'s payload, undefined ux_and_* imports
# and all); libUXAndroid.so is the NDK-built shim the manifest's lib_name
# points at, which owns onCreate, binds those imports, and delegates to the
# app lib's glue.  The bridge dex rides from tools/android/ (the committed
# bootstrap).  Packaging is script-side until 031's --with-dex (and a
# --lib-name/--with-lib sibling) fold it into one xcc line.
set -e
here=$(cd "$(dirname "$0")" && pwd)
ux="$here/../../frameworks/uxkit"
xcc=${XCC:-xcc}
A="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="$A/platform-tools/adb"
BT=$(ls -d "$A"/build-tools/* 2>/dev/null | sort -V | tail -1)
NDKBIN=$(ls -d "$A"/ndk/*/toolchains/llvm/prebuilt/*/bin 2>/dev/null | sort -V | tail -1)
PLATJAR=$(ls "$A"/platforms/android-*/android.jar 2>/dev/null | sort -V | tail -1)
{ [ -n "$BT" ] && [ -n "$NDKBIN" ] && [ -x "$ADB" ]; } || { echo "== rocks-android: skipped (no SDK/NDK) =="; exit 0; }
"$ADB" get-state >/dev/null 2>&1 || { echo "== rocks-android: skipped (no device) =="; exit 0; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== rocks-android: building the app lib (pure xcc) + the shim (NDK) =="
"$xcc" -A android --emit-apk -D RK_ANDROID -I "$ux" -I "$here/xc" "$here/xc/rocks_main.xc" -o "$work/xtapp.apk" -q
mkdir -p "$work/lib/arm64-v8a"
unzip -p "$work/xtapp.apk" "lib/arm64-v8a/*.so" > "$work/lib/arm64-v8a/libxtapp.so"
# The load-order keystone: a NEEDED entry on the app lib makes bionic bind
# its ux_and_* imports against the shim (see addneeded.py's header).
python3 "$ux/tools/android/addneeded.py" "$work/lib/arm64-v8a/libxtapp.so" libUXAndroid.so
"$NDKBIN/aarch64-linux-android26-clang" -shared -fPIC -Wl,-soname,libUXAndroid.so \
    "$ux/libUXAndroid.c" -llog -landroid -o "$work/lib/arm64-v8a/libUXAndroid.so"

echo "== rocks-android: packaging the two-lib APK =="
cat > "$work/AndroidManifest.xml" <<'EOF'
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
          package="org.compile_xc.rocks">
  <uses-sdk android:minSdkVersion="26" android:targetSdkVersion="35"/>
  <application android:hasCode="true" android:label="Rocks" android:enableOnBackInvokedCallback="true">
    <activity android:name="android.app.NativeActivity" android:exported="true">
      <meta-data android:name="android.app.lib_name" android:value="UXAndroid"/>
      <intent-filter>
        <action android:name="android.intent.action.MAIN"/>
        <category android:name="android.intent.category.LAUNCHER"/>
      </intent-filter>
    </activity>
  </application>
</manifest>
EOF
"$BT/aapt2" link -I "$PLATJAR" --manifest "$work/AndroidManifest.xml" -o "$work/unaligned.apk"
cp "$ux/tools/android/classes.dex" "$work/"
( cd "$work" && zip -q unaligned.apk classes.dex lib/arm64-v8a/libUXAndroid.so lib/arm64-v8a/libxtapp.so )
"$BT/zipalign" -f 4 "$work/unaligned.apk" "$work/aligned.apk"
KS="$ux/tools/android/debug.keystore"
[ -f "$KS" ] || keytool -genkeypair -keystore "$KS" -storepass uxkit1 -alias ux -dname "CN=uxkit" -keyalg RSA -validity 10000 2>/dev/null
"$BT/apksigner" sign --ks "$KS" --ks-pass pass:uxkit1 --out "$work/rocks.apk" "$work/aligned.apk" 2>/dev/null

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
# on screen: the canvas pane (the middle of the editor) is white, as the editor draws it
px=$(magick "$shot" -gravity center -crop 1x1+0+0 -format '%[fx:int(255*r)],%[fx:int(255*g)],%[fx:int(255*b)]' info: 2>/dev/null || echo "?")
echo "screen centre pixel: $px"
[ "$px" = "255,255,255" ] || { echo "== rocks-android: FAILED (the editor is not on screen) =="; exit 1; }
echo "== rocks-android: OK — Rocks runs on Android =="
