#!/bin/sh
# run_android_scroll.sh — the `android-scroll` gate: a scroll view is a real ScrollView on the
# emulator.  Real input: the app logs where it wants a tap (TAP<n> x y) or a swipe (SWIPE x0 y0 x1 y1)
# on the screen, and the gate makes it with adb input.  It reads only its own app's log, and stops
# the app on the way out.  Skips cleanly without an emulator.
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
{ [ -n "$NDKBIN" ] && [ -x "$ADB" ]; } || { echo "== android-scroll: skipped (no SDK/NDK) =="; exit 0; }
"$ADB" get-state >/dev/null 2>&1 || { echo "== android-scroll: skipped (no device) =="; exit 0; }

# On the way out, stop the app: a task left behind is what Android goes back to when the next
# document-picker gate's picker closes, and the relaunched app's log lines land in that gate's.
work=$(mktemp -d); trap '"$ADB" shell am force-stop org.compile_xc.uxscroll >/dev/null 2>&1; rm -rf "$work"' EXIT
echo "== android-scroll: the shim (NDK), then the APK in one xcc line =="
"$NDKBIN/aarch64-linux-android26-clang" -shared -fPIC -Wl,-soname,libUXAndroid.so \
    "$here/libUXAndroid.c" -llog -landroid -o "$work/libUXAndroid.so"
# --needed binds the app lib's ux_and_* imports against the shim; --lib-name
# makes the shim the library Android loads first; the bridge dex rides from tools/android/.
"$xcc" -A android --emit-apk -I "$here" "$here/test_android_scroll.xc" \
    --needed libUXAndroid.so --with-lib "$work/libUXAndroid.so" --lib-name UXAndroid \
    --with-dex "$here/tools/android/classes.dex" -o "$work/uxscroll.apk" -q 2>/dev/null

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
