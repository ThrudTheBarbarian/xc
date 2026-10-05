#!/bin/sh
# run_android_menu.sh — the `android-menu` gate: the app's menus as a PopupMenu from an overflow
# button on the emulator.  Once the test is ready, the gate taps for REAL through uiautomator: the
# button (content-desc "Menu"), then File, then New, each found by its text on the live screen.
# ANDROID_MENU_SHOT=<png> screencaps the open menu.  Skips cleanly without an emulator.
#
# The two-lib APK (see libUXAndroid.c's header), in one xcc line: the app lib is the pure xcc
# payload, its ux_and_* imports bound (--needed) against libUXAndroid.so, the NDK-built shim that
# Android loads first (--lib-name), which owns onCreate and delegates to the app lib's glue.  The
# bridge dex rides from tools/android/ (the committed bootstrap).
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
A="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="$A/platform-tools/adb"
NDKBIN=$(ls -d "$A"/ndk/*/toolchains/llvm/prebuilt/*/bin 2>/dev/null | sort -V | tail -1)
{ [ -n "$NDKBIN" ] && [ -x "$ADB" ]; } || { echo "== android-menu: skipped (no SDK/NDK) =="; exit 0; }
"$ADB" get-state >/dev/null 2>&1 || { echo "== android-menu: skipped (no device) =="; exit 0; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== android-menu: the shim (NDK), then the APK in one xcc line =="
"$NDKBIN/aarch64-linux-android26-clang" -shared -fPIC -Wl,-soname,libUXAndroid.so \
    "$here/libUXAndroid.c" -llog -landroid -o "$work/libUXAndroid.so"
# --needed binds the app lib's ux_and_* imports against the shim; --lib-name
# makes the shim the library Android loads first; the bridge dex rides from tools/android/.
"$xcc" -A android --emit-apk -D TABLE_ANDROID -I "$here" "$here/test_menu_native.xc" \
    --needed libUXAndroid.so --with-lib "$work/libUXAndroid.so" --lib-name UXAndroid \
    --with-dex "$here/tools/android/classes.dex" -o "$work/uxmenu.apk" -q 2>/dev/null

echo "== android-menu: installing + launching =="
# A regenerated keystore signs with a new key, which Android refuses as an
# update of a package signed by the old one. Replace it rather than fail.
"$ADB" install -r "$work/uxmenu.apk" >/dev/null 2>&1 || {
    "$ADB" uninstall org.compile_xc.uxmenu >/dev/null 2>&1
    "$ADB" install "$work/uxmenu.apk" >/dev/null
}
"$ADB" logcat -c
"$ADB" shell am start -S --activity-clear-task -n org.compile_xc.uxmenu/android.app.NativeActivity >/dev/null 2>&1
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
"$ADB" shell rm -f /sdcard/ux.xml # the screen dumps would show up in the device's recent files
echo "$out" | grep -v '^-' | grep -E 'ok |FAIL|PASS|menu:' | tail -20
echo "$out" | grep -q "PASS:" || { echo "== android-menu: FAILED =="; exit 1; }
[ "$saveOn" = "new=True save=False" ] || { echo "== android-menu: FAILED (on screen New must be enabled and Save disabled: $saveOn) =="; exit 1; }
echo "== android-menu: OK =="
