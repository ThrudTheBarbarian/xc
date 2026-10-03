#!/bin/sh
# run_android_table.sh — the `android-table` gate: UXTableView realized as a real ListView (under a
# header of the column titles) on the emulator: rows and cells from the datasource, a tap into the
# model, the app's selection shown natively, a reload.  ANDROID_TABLE_SHOT=<png> also screencaps it.
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
{ [ -n "$BT" ] && [ -n "$NDKBIN" ] && [ -x "$ADB" ]; } || { echo "== android-table: skipped (no SDK/NDK) =="; exit 0; }
"$ADB" get-state >/dev/null 2>&1 || { echo "== android-table: skipped (no device) =="; exit 0; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== android-table: building the app lib (pure xcc) + the shim (NDK) =="
"$xcc" -A android --emit-apk -D TABLE_ANDROID -I "$here" "$here/test_table_native.xc" -o "$work/xtapp.apk" -q 2>/dev/null
mkdir -p "$work/lib/arm64-v8a"
unzip -p "$work/xtapp.apk" "lib/arm64-v8a/*.so" > "$work/lib/arm64-v8a/libxtapp.so"
# The load-order keystone: a NEEDED entry on the app lib makes bionic bind
# its ux_and_* imports against the shim (see addneeded.py's header).
python3 "$here/tools/android/addneeded.py" "$work/lib/arm64-v8a/libxtapp.so" libUXAndroid.so
"$NDKBIN/aarch64-linux-android26-clang" -shared -fPIC -Wl,-soname,libUXAndroid.so \
    "$here/libUXAndroid.c" -llog -landroid -o "$work/lib/arm64-v8a/libUXAndroid.so"

echo "== android-table: packaging the two-lib APK =="
cat > "$work/AndroidManifest.xml" <<'EOF'
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
          package="org.compile_xc.uxtable">
  <uses-sdk android:minSdkVersion="26" android:targetSdkVersion="35"/>
  <application android:hasCode="true" android:label="uxtable" android:enableOnBackInvokedCallback="true">
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
"$BT/apksigner" sign --ks "$KS" --ks-pass pass:uxkit1 --out "$work/uxtable.apk" "$work/aligned.apk" 2>/dev/null

echo "== android-table: installing + launching =="
# A regenerated keystore signs with a new key, which Android refuses as an
# update of a package signed by the old one. Replace it rather than fail.
"$ADB" install -r "$work/uxtable.apk" >/dev/null 2>&1 || {
    "$ADB" uninstall org.compile_xc.uxtable >/dev/null 2>&1
    "$ADB" install "$work/uxtable.apk" >/dev/null
}
"$ADB" logcat -c
"$ADB" shell am start -S --activity-clear-task -n org.compile_xc.uxtable/android.app.NativeActivity >/dev/null 2>&1
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
[ -n "$ANDROID_TABLE_SHOT" ] && "$ADB" exec-out screencap -p > "$ANDROID_TABLE_SHOT"
echo "$out" | grep -q "PASS:" || { echo "== android-table: FAILED =="; exit 1; }
echo "== android-table: OK =="
