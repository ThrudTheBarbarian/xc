#!/bin/sh
# run_android_scroll.sh — the `android-scroll` gate: a scroll view is a real ScrollView on the
# emulator.  Real input: the app logs where it wants a tap (TAP<n> x y) or a swipe (SWIPE x0 y0 x1 y1)
# on the screen, and the gate makes it with adb input.  It reads only its own app's log, and stops
# the app on the way out.  Skips cleanly without an emulator.
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
{ [ -n "$BT" ] && [ -n "$NDKBIN" ] && [ -x "$ADB" ]; } || { echo "== android-scroll: skipped (no SDK/NDK) =="; exit 0; }
"$ADB" get-state >/dev/null 2>&1 || { echo "== android-scroll: skipped (no device) =="; exit 0; }

# On the way out, stop the app: a task left behind is what Android goes back to when the next
# document-picker gate's picker closes, and the relaunched app's log lines land in that gate's.
work=$(mktemp -d); trap '"$ADB" shell am force-stop org.compile_xc.uxscroll >/dev/null 2>&1; rm -rf "$work"' EXIT
echo "== android-scroll: building the app lib (pure xcc) + the shim (NDK) =="
"$xcc" -A android --emit-apk -I "$here" "$here/test_android_scroll.xc" -o "$work/xtapp.apk" -q 2>/dev/null
mkdir -p "$work/lib/arm64-v8a"
unzip -p "$work/xtapp.apk" "lib/arm64-v8a/*.so" > "$work/lib/arm64-v8a/libxtapp.so"
# The load-order keystone: a NEEDED entry on the app lib makes bionic bind
# its ux_and_* imports against the shim (see addneeded.py's header).
python3 "$here/tools/android/addneeded.py" "$work/lib/arm64-v8a/libxtapp.so" libUXAndroid.so
"$NDKBIN/aarch64-linux-android26-clang" -shared -fPIC -Wl,-soname,libUXAndroid.so \
    "$here/libUXAndroid.c" -llog -landroid -o "$work/lib/arm64-v8a/libUXAndroid.so"

echo "== android-scroll: packaging the two-lib APK =="
cat > "$work/AndroidManifest.xml" <<'EOF'
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
          package="org.compile_xc.uxscroll">
  <uses-sdk android:minSdkVersion="26" android:targetSdkVersion="35"/>
  <application android:hasCode="true" android:label="uxscroll" android:enableOnBackInvokedCallback="true">
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
"$BT/apksigner" sign --ks "$KS" --ks-pass pass:uxkit1 --out "$work/uxscroll.apk" "$work/aligned.apk" 2>/dev/null

echo "== android-scroll: installing + launching =="
# A regenerated keystore signs with a new key, which Android refuses as an
# update of a package signed by the old one. Replace it rather than fail.
"$ADB" install -r "$work/uxscroll.apk" >/dev/null 2>&1 || {
    "$ADB" uninstall org.compile_xc.uxscroll >/dev/null 2>&1
    "$ADB" install "$work/uxscroll.apk" >/dev/null
}
"$ADB" logcat -c
"$ADB" shell am start -S --activity-clear-task -n org.compile_xc.uxscroll/android.app.NativeActivity >/dev/null 2>&1
done1=; done2=; swiped=
for i in $(seq 1 120); do
  pid=$("$ADB" shell pidof org.compile_xc.uxscroll 2>/dev/null | tr -d '\r')
  [ -n "$pid" ] && out=$("$ADB" logcat -d --pid="$pid" -s xcapp uxkit)
  for n in 1 2; do
    eval "d=\$done$n"
    [ -n "$d" ] && continue
    xy=$(echo "$out" | sed -n "s/.*TAP$n \([0-9]*\) \([0-9]*\).*/\1 \2/p" | head -1)
    [ -n "$xy" ] || continue
    sleep 1
    "$ADB" shell input tap $xy
    eval "done$n=1"
  done
  if [ -z "$swiped" ]; then
    sw=$(echo "$out" | sed -n "s/.*SWIPE \([0-9]*\) \([0-9]*\) \([0-9]*\) \([0-9]*\).*/\1 \2 \3 \4/p" | head -1)
    if [ -n "$sw" ]; then sleep 1; "$ADB" shell input swipe $sw 400; swiped=1; fi
  fi
  echo "$out" | grep -qE "PASS:|FAIL:" && break
  sleep 1
done
echo "$out" | grep -v '^-' | grep -E 'ok |FAIL|PASS|TAP|SWIPE|\(' | sed 's/^.*xcapp *: //' | tail -20
echo "$out" | grep -q "PASS:" || { echo "== android-scroll: FAILED =="; exit 1; }
echo "== android-scroll: OK =="
