#!/bin/sh
# run_android_shield.sh — the `android-shield` gate: a UXShieldView over a native Button takes a
# REAL tap (adb input) that would have pressed the button, in the window's content coordinates;
# hidden, it lets the same tap through.  The app logs where to tap (TAP<n> x y); the gate taps it.
# It reads only its own app's log, and stops the app on the way out.  Skips cleanly without an
# emulator.
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
{ [ -n "$NDKBIN" ] && [ -x "$ADB" ]; } || { echo "== android-shield: skipped (no SDK/NDK) =="; exit 0; }
"$ADB" get-state >/dev/null 2>&1 || { echo "== android-shield: skipped (no device) =="; exit 0; }

# On the way out, stop the app: a task left behind is what Android goes back to when the next
# document-picker gate's picker closes, and the relaunched app's log lines land in that gate's.
work=$(mktemp -d); trap '"$ADB" shell am force-stop org.compile_xc.uxshield >/dev/null 2>&1; rm -rf "$work"' EXIT
echo "== android-shield: the shim (NDK), then the APK in one xcc line =="
"$NDKBIN/aarch64-linux-android26-clang" -shared -fPIC -Wl,-soname,libUXAndroid.so \
    "$here/libUXAndroid.c" -llog -landroid -o "$work/libUXAndroid.so"
# --needed binds the app lib's ux_and_* imports against the shim; --lib-name
# makes the shim the library Android loads first; the bridge dex rides from tools/android/.
"$xcc" -A android --emit-apk -I "$here" "$here/test_android_shield.xc" \
    --needed libUXAndroid.so --with-lib "$work/libUXAndroid.so" --lib-name UXAndroid \
    --with-dex "$here/tools/android/classes.dex" -o "$work/uxshield.apk" -q 2>/dev/null

echo "== android-shield: installing + launching =="
# A regenerated keystore signs with a new key, which Android refuses as an
# update of a package signed by the old one. Replace it rather than fail.
"$ADB" install -r "$work/uxshield.apk" >/dev/null 2>&1 || {
    "$ADB" uninstall org.compile_xc.uxshield >/dev/null 2>&1
    "$ADB" install "$work/uxshield.apk" >/dev/null
}
"$ADB" logcat -c
"$ADB" shell am start -S --activity-clear-task -n org.compile_xc.uxshield/android.app.NativeActivity >/dev/null 2>&1
done1=; done2=; done3=
for i in $(seq 1 90); do
  pid=$("$ADB" shell pidof org.compile_xc.uxshield 2>/dev/null | tr -d '\r')
  [ -n "$pid" ] && out=$("$ADB" logcat -d --pid="$pid" -s xcapp uxkit)
  for n in 1 2 3; do
    eval "d=\$done$n"
    [ -n "$d" ] && continue
    xy=$(echo "$out" | sed -n "s/.*TAP$n \([0-9]*\) \([0-9]*\).*/\1 \2/p" | head -1)
    [ -n "$xy" ] || continue
    sleep 1
    "$ADB" shell input tap $xy
    eval "done$n=1"
  done
  echo "$out" | grep -qE "PASS:|FAIL:" && break
  sleep 1
done
echo "$out" | grep -v '^-' | grep -E 'ok |FAIL|PASS|TAP' | sed 's/^.*xcapp *: //' | tail -20
echo "$out" | grep -q "PASS:" || { echo "== android-shield: FAILED =="; exit 1; }
echo "== android-shield: OK =="
