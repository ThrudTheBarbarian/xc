#!/bin/sh
# run_android_outline.sh — the `android-outline` gate: UXOutlineView realized as the native ListView on the
# emulator: flattened rows, an arrow that opens an item (tapped for REAL), indent, selection by item.  ANDROID_OUTLINE_SHOT=<png> also screencaps it.
# Skips cleanly without an emulator.
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
{ [ -n "$BT" ] && [ -n "$NDKBIN" ] && [ -x "$ADB" ]; } || { echo "== android-outline: skipped (no SDK/NDK) =="; exit 0; }
"$ADB" get-state >/dev/null 2>&1 || { echo "== android-outline: skipped (no device) =="; exit 0; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== android-outline: building the app lib (pure xcc) + the shim (NDK) =="
"$xcc" -A android --emit-apk -D TABLE_ANDROID -I "$here" "$here/test_outline_native.xc" -o "$work/xtapp.apk" -q 2>/dev/null
mkdir -p "$work/lib/arm64-v8a"
unzip -p "$work/xtapp.apk" "lib/arm64-v8a/*.so" > "$work/lib/arm64-v8a/libxtapp.so"
# The load-order keystone: a NEEDED entry on the app lib makes bionic bind
# its ux_and_* imports against the shim (see addneeded.py's header).
python3 "$here/tools/android/addneeded.py" "$work/lib/arm64-v8a/libxtapp.so" libUXAndroid.so
"$NDKBIN/aarch64-linux-android26-clang" -shared -fPIC -Wl,-soname,libUXAndroid.so \
    "$here/libUXAndroid.c" -llog -landroid -o "$work/lib/arm64-v8a/libUXAndroid.so"

echo "== android-outline: packaging the two-lib APK =="
cat > "$work/AndroidManifest.xml" <<'EOF'
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
          package="org.compile_xc.uxoutline">
  <uses-sdk android:minSdkVersion="26" android:targetSdkVersion="35"/>
  <application android:hasCode="true" android:label="uxoutline" android:enableOnBackInvokedCallback="true">
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
"$BT/apksigner" sign --ks "$KS" --ks-pass pass:uxkit1 --out "$work/uxoutline.apk" "$work/aligned.apk" 2>/dev/null

echo "== android-outline: installing + launching =="
# A regenerated keystore signs with a new key, which Android refuses as an
# update of a package signed by the old one. Replace it rather than fail.
"$ADB" install -r "$work/uxoutline.apk" >/dev/null 2>&1 || {
    "$ADB" uninstall org.compile_xc.uxoutline >/dev/null 2>&1
    "$ADB" install "$work/uxoutline.apk" >/dev/null
}
"$ADB" logcat -c
"$ADB" shell am start -n org.compile_xc.uxoutline/android.app.NativeActivity >/dev/null 2>&1
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
