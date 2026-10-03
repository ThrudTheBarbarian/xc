#!/bin/sh
# run_android_menu.sh — the `android-menu` gate: the app's menus as a PopupMenu from an overflow
# button on the emulator.  Once the test is ready, the gate taps for REAL through uiautomator: the
# button (content-desc "Menu"), then File, then New, each found by its text on the live screen.
# ANDROID_MENU_SHOT=<png> screencaps the open menu.  Skips cleanly without an emulator.
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
{ [ -n "$BT" ] && [ -n "$NDKBIN" ] && [ -x "$ADB" ]; } || { echo "== android-menu: skipped (no SDK/NDK) =="; exit 0; }
"$ADB" get-state >/dev/null 2>&1 || { echo "== android-menu: skipped (no device) =="; exit 0; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== android-menu: building the app lib (pure xcc) + the shim (NDK) =="
"$xcc" -A android --emit-apk -D TABLE_ANDROID -I "$here" "$here/test_menu_native.xc" -o "$work/xtapp.apk" -q 2>/dev/null
mkdir -p "$work/lib/arm64-v8a"
unzip -p "$work/xtapp.apk" "lib/arm64-v8a/*.so" > "$work/lib/arm64-v8a/libxtapp.so"
# The load-order keystone: a NEEDED entry on the app lib makes bionic bind
# its ux_and_* imports against the shim (see addneeded.py's header).
python3 "$here/tools/android/addneeded.py" "$work/lib/arm64-v8a/libxtapp.so" libUXAndroid.so
"$NDKBIN/aarch64-linux-android26-clang" -shared -fPIC -Wl,-soname,libUXAndroid.so \
    "$here/libUXAndroid.c" -llog -landroid -o "$work/lib/arm64-v8a/libUXAndroid.so"

echo "== android-menu: packaging the two-lib APK =="
cat > "$work/AndroidManifest.xml" <<'EOF'
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
          package="org.compile_xc.uxmenu">
  <uses-sdk android:minSdkVersion="26" android:targetSdkVersion="35"/>
  <application android:hasCode="true" android:label="uxmenu" android:enableOnBackInvokedCallback="true">
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
"$BT/apksigner" sign --ks "$KS" --ks-pass pass:uxkit1 --out "$work/uxmenu.apk" "$work/aligned.apk" 2>/dev/null

echo "== android-menu: installing + launching =="
# A regenerated keystore signs with a new key, which Android refuses as an
# update of a package signed by the old one. Replace it rather than fail.
"$ADB" install -r "$work/uxmenu.apk" >/dev/null 2>&1 || {
    "$ADB" uninstall org.compile_xc.uxmenu >/dev/null 2>&1
    "$ADB" install "$work/uxmenu.apk" >/dev/null
}
"$ADB" logcat -c
"$ADB" shell am start -n org.compile_xc.uxmenu/android.app.NativeActivity >/dev/null 2>&1
# Tap a view found on the live screen by its text or content-desc (uiautomator's dump).
tapon() {
  "$ADB" shell uiautomator dump /sdcard/ux.xml >/dev/null 2>&1
  b=$("$ADB" shell cat /sdcard/ux.xml | tr '>' '\n' | grep -E "(text|content-desc)=\"$1\"" | head -1 \
      | sed -n 's/.*bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]".*/\1 \2 \3 \4/p')
  [ -n "$b" ] || { echo "(no \"$1\" on screen)"; return 1; }
  set -- $b
  "$ADB" shell input tap $(( ($1 + $3) / 2 )) $(( ($2 + $4) / 2 ))
  sleep 1
}
tapped=0
for i in $(seq 1 50); do
  out=$("$ADB" logcat -d -s xcapp uxkit)
  if [ $tapped = 0 ] && echo "$out" | grep -q MENUREADY; then
    tapped=1
    if tapon Menu && tapon File; then
      [ -n "$ANDROID_MENU_SHOT" ] && "$ADB" exec-out screencap -p > "$ANDROID_MENU_SHOT"
      # the item the app disabled must be disabled on the screen, not just in the model: Android
      # disables the menu ROW (the title text inside keeps its own flag), so look up the ancestors
      "$ADB" shell uiautomator dump /sdcard/ux.xml >/dev/null 2>&1
      "$ADB" pull /sdcard/ux.xml "$work/ux.xml" >/dev/null 2>&1
      saveOn=$(python3 - "$work/ux.xml" <<'PY'
import sys, xml.etree.ElementTree as ET
state = {}
def walk(n, path):
    if n.get('text') in ('New', 'Save'):
        state[n.get('text')] = all(a.get('enabled') == 'true' for a in path[1:] + [n])
    for c in n:
        walk(c, path + [n])
walk(ET.parse(sys.argv[1]).getroot(), [])
print('new=%s save=%s' % (state.get('New'), state.get('Save')))
PY
)
      echo "(on screen: $saveOn)"
      tapon New
    fi
  fi
  echo "$out" | grep -qE "PASS:|FAIL" && break
  sleep 1
done
echo "$out" | grep -v '^-' | grep -E 'ok |FAIL|PASS|menu:' | tail -20
echo "$out" | grep -q "PASS:" || { echo "== android-menu: FAILED =="; exit 1; }
[ "$saveOn" = "new=True save=False" ] || { echo "== android-menu: FAILED (on screen New must be enabled and Save disabled: $saveOn) =="; exit 1; }
echo "== android-menu: OK =="
