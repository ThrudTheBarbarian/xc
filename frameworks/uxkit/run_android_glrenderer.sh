#!/bin/sh
# run_android_glrenderer.sh — the `android-glrenderer` gate: test_gl_renderer.xc, a GL renderer written
# against UXGL.xc, on the emulator, its gl* calls bound to the platform's libGLESv3.  Skips cleanly
# when the SDK or a device is absent.
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
xcc=${XCC:-xcc}
A="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="$A/platform-tools/adb"
BT=$(ls -d "$A"/build-tools/* 2>/dev/null | sort -V | tail -1)
NDKBIN=$(ls -d "$A"/ndk/*/toolchains/llvm/prebuilt/*/bin 2>/dev/null | sort -V | tail -1)
PLATJAR=$(ls "$A"/platforms/android-*/android.jar 2>/dev/null | sort -V | tail -1)
{ [ -n "$BT" ] && [ -n "$NDKBIN" ] && [ -x "$ADB" ]; } || { echo "== android-glrenderer: skipped (no SDK/NDK) =="; exit 0; }
"$ADB" get-state >/dev/null 2>&1 || { echo "== android-glrenderer: skipped (no device) =="; exit 0; }

work=$(mktemp -d); trap '"$ADB" shell am force-stop org.compile_xc.uxglr >/dev/null 2>&1; rm -rf "$work"' EXIT
echo "== android-glrenderer: building the app lib (pure xcc) + the shim (NDK) =="
"$xcc" -A android --emit-apk -I "$here" "$here/test_gl_renderer.xc" -o "$work/xtapp.apk" -q 2>/dev/null
mkdir -p "$work/lib/arm64-v8a"
unzip -p "$work/xtapp.apk" "lib/arm64-v8a/*.so" > "$work/lib/arm64-v8a/libxtapp.so"
# The load-order keystone: a NEEDED entry on the app lib makes bionic bind
# its ux_and_* imports against the shim (see addneeded.py's header).
python3 "$here/tools/android/addneeded.py" "$work/lib/arm64-v8a/libxtapp.so" libUXAndroid.so
# ...and on the platform's GLES, where the renderer's gl* calls (UXGL.xc) live
python3 "$here/tools/android/addneeded.py" "$work/lib/arm64-v8a/libxtapp.so" libGLESv3.so
"$NDKBIN/aarch64-linux-android26-clang" -shared -fPIC -Wl,-soname,libUXAndroid.so \
    "$here/libUXAndroid.c" -llog -landroid -o "$work/lib/arm64-v8a/libUXAndroid.so"

echo "== android-glrenderer: packaging the two-lib APK =="
cat > "$work/AndroidManifest.xml" <<'EOF'
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
          package="org.compile_xc.uxglr">
  <uses-sdk android:minSdkVersion="26" android:targetSdkVersion="35"/>
  <application android:hasCode="true" android:label="uxglr">
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
cp "$here/tools/android/classes.dex" "$work/"
( cd "$work" && zip -q unaligned.apk classes.dex lib/arm64-v8a/libUXAndroid.so lib/arm64-v8a/libxtapp.so )
"$BT/zipalign" -f 4 "$work/unaligned.apk" "$work/aligned.apk"
KS="$here/tools/android/debug.keystore"
[ -f "$KS" ] || keytool -genkeypair -keystore "$KS" -storepass uxkit1 -alias ux -dname "CN=uxkit" -keyalg RSA -validity 10000 2>/dev/null
"$BT/apksigner" sign --ks "$KS" --ks-pass pass:uxkit1 --out "$work/uxglr.apk" "$work/aligned.apk" 2>/dev/null

echo "== android-glrenderer: installing + launching =="
# A regenerated keystore signs with a new key, which Android refuses as an
# update of a package signed by the old one. Replace it rather than fail.
"$ADB" install -r "$work/uxglr.apk" >/dev/null 2>&1 || {
    "$ADB" uninstall org.compile_xc.uxglr >/dev/null 2>&1
    "$ADB" install "$work/uxglr.apk" >/dev/null
}
"$ADB" logcat -c
"$ADB" shell am start -S --activity-clear-task -n org.compile_xc.uxglr/android.app.NativeActivity >/dev/null 2>&1
sleep 9
out=$("$ADB" logcat -d -s xcapp uxkit)
echo "$out" | grep -v '^-' | tail -20
echo "$out" | grep -q "PASS:" || { echo "== android-glrenderer: FAILED =="; exit 1; }
echo "== android-glrenderer: OK =="
