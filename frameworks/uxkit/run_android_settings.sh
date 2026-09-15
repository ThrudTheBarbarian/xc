#!/bin/sh
# make android-settings — UXKeyValueStore over REAL SharedPreferences, written
# by one launch, read by the next.  `pm clear` empties the app's data first,
# so the pair is hermetic and the pass marker self-sequences the two launches.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
A="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="$A/platform-tools/adb"
BT=$(ls -d "$A"/build-tools/* 2>/dev/null | sort -V | tail -1)
NDKBIN=$(ls -d "$A"/ndk/*/toolchains/llvm/prebuilt/*/bin 2>/dev/null | sort -V | tail -1)
PLATJAR=$(ls "$A"/platforms/android-*/android.jar 2>/dev/null | sort -V | tail -1)
{ [ -n "$BT" ] && [ -n "$NDKBIN" ] && [ -x "$ADB" ]; } || { echo "== android-settings: skipped (no SDK/NDK) =="; exit 0; }
"$ADB" get-state >/dev/null 2>&1 || { echo "== android-settings: skipped (no device) =="; exit 0; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== android-settings: building the two-lib APK =="
"$xcc" -A android --emit-apk -I "$here" "$here/test_android_settings.xc" -o "$work/xtapp.apk" -q 2>/dev/null
mkdir -p "$work/lib/arm64-v8a"
unzip -p "$work/xtapp.apk" "lib/arm64-v8a/*.so" > "$work/lib/arm64-v8a/libxtapp.so"
python3 "$here/tools/android/addneeded.py" "$work/lib/arm64-v8a/libxtapp.so" libUXAndroid.so >/dev/null
"$NDKBIN/aarch64-linux-android26-clang" -shared -fPIC -Wl,-soname,libUXAndroid.so \
    "$here/libUXAndroid.c" -llog -landroid -o "$work/lib/arm64-v8a/libUXAndroid.so"
cat > "$work/AndroidManifest.xml" <<'EOF'
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
          package="org.compile_xc.uxset">
  <uses-sdk android:minSdkVersion="26" android:targetSdkVersion="35"/>
  <application android:hasCode="true" android:label="uxset">
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
# Self-signed throwaway for local APK signing, generated on demand. It is NOT
# in the repo: a private key does not belong in version control, even a
# disposable one. Every script that signs makes it the same way.
KS="$here/tools/android/debug.keystore"
[ -f "$KS" ] || keytool -genkeypair -keystore "$KS" -storepass uxkit1 -alias ux \
    -dname "CN=uxkit" -keyalg RSA -validity 10000 2>/dev/null
"$BT/apksigner" sign --ks "$KS" --ks-pass pass:uxkit1 \
    --out "$work/uxset.apk" "$work/aligned.apk" 2>/dev/null

# A regenerated keystore signs with a new key, which Android refuses as an
# update of a package signed by the old one. Replace it rather than fail.
"$ADB" install -r "$work/uxset.apk" >/dev/null 2>&1 || {
    "$ADB" uninstall org.compile_xc.uxset >/dev/null 2>&1
    "$ADB" install "$work/uxset.apk" >/dev/null
}
"$ADB" shell pm clear org.compile_xc.uxset >/dev/null

echo "== android-settings: launch 1 (write) =="
"$ADB" logcat -c
"$ADB" shell am start -n org.compile_xc.uxset/android.app.NativeActivity >/dev/null 2>&1
sleep 5
"$ADB" logcat -d -s xcapp | grep -q "WROTE: first launch complete" || {
    echo "== android-settings: FAILED (write pass) =="; "$ADB" logcat -d -s xcapp uxkit | tail -8; exit 1; }
"$ADB" logcat -d -s xcapp | grep -v '^-' | sed 's/.*xcapp   ://;s/^/ /'

echo "== android-settings: launch 2 (a fresh process reads it back) =="
"$ADB" logcat -c
"$ADB" shell am start -n org.compile_xc.uxset/android.app.NativeActivity >/dev/null 2>&1
sleep 5
out=$("$ADB" logcat -d -s xcapp | grep -v '^-' | sed 's/.*xcapp   ://')
printf '%s\n' "$out"
if printf '%s\n' "$out" | grep -q "PASS: settings persist in SharedPreferences"; then
    echo "== android-settings: PASS — preferences live in SharedPreferences =="
else
    echo "== android-settings: FAIL =="; exit 1
fi
