#!/bin/bash
# no-self-host.sh — `--no-self-host` links through clang against the same
# runtime as the in-house link (2026-11-01)
#
# On arm64 macOS `--no-self-host` hands the link to clang. It used to compile a
# C runtime the driver generated beside the program, which had drifted from the
# object layout the back ends emit: from 0.9's compact header on, any program
# that made an object failed to link (`_Object$hash` and others undefined), and
# before that its header still had the 16-bit refcount. Both drivers now give
# clang crt-macos.s, rt-macos.s and the per-class allocators, entered at
# _xtc_start. Checked: a program with classes, a destructor, an array of
# objects, a weak reference and strings builds through clang with both
# compilers and prints what the in-house build prints, and a -fbounds-check
# build does too. Android goes through the NDK's clang in the shipped compiler
# (#31; the reference refuses it): an executable and an APK, run where a
# device or emulator is attached. macOS only (clang is the host's).
#
#   bash tests/driver/no-self-host.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
[ "$(uname -s)" = Darwin ] || { echo "no-self-host: skipped (not macOS)"; exit 0; }
command -v clang > /dev/null || { echo "no-self-host: skipped (no clang)"; exit 0; }
REF=${REF:-bin/osx/xcc}
XC=${XC:-bin/osx/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0
NDK=$(ls -d "${ANDROID_NDK_HOME:-/nonexistent}" "${ANDROID_HOME:-$HOME/Library/Android/sdk}"/ndk/* 2>/dev/null | tail -1)
ADB=$(command -v adb || ls "${ANDROID_HOME:-$HOME/Library/Android/sdk}"/platform-tools/adb 2>/dev/null)
cat > "$W/p.xc" <<'XC'
#import "Stdio.xc"
u32 gGone;
class Box
    {
    i32 v;
    void init(i32 x) { v = x; }
    void dealloc(void) { gGone = gGone + (u32)1; }
    }
i32 main(void)
    {
    Box* b = new Box(41);
    weak Box* w = b;
    Array* boxes = new Array();
    for (i32 i = (i32)0; i < (i32)5; i = i + (i32)1)
        boxes.add((Object*)new Box(i));
    i32 sum = (i32)0;
    for (u32 i = (u32)0; i < boxes.count(); i = i + (u32)1)
        sum = sum + ((Box*)boxes.get(i)).v;
    String* s = String.withCString("abc");
    s.appendFormat("%d", b.v + (i32)1);
    boxes = (Array*)0;
    b = (Box*)0;
    Stdio.printf("%s sum %d gone %u weak %s\n", s.cString(), sum, gGone, w == (Box*)0 ? "nil" : "set");
    return (i32)0;
    }
XC
want="abc42 sum 10 gone 6 weak nil"
for s in r x; do
    c=$REF; [ $s = x ] && c=$XC
    n=$(basename "$c")
    "$c" -q -O2 -o "$W/$s-in" "$W/p.xc" > "$W/e" 2>&1 || { echo "FAIL no-self-host: $n in-house build: $(head -c 200 "$W/e")"; fail=1; continue; }
    got=$("$W/$s-in")
    [ "$got" = "$want" ] || { echo "FAIL no-self-host: $n in-house build prints '$got' (want '$want')"; fail=1; }
    for f in "" "-fbounds-check"; do
        "$c" -q -O2 $f --no-self-host -o "$W/$s-clang" "$W/p.xc" > "$W/e" 2>&1 \
            || { echo "FAIL no-self-host: $n $f does not link through clang: $(grep -m2 -E 'error|Undefined|_' "$W/e" | head -c 300)"; fail=1; continue; }
        got=$("$W/$s-clang" 2>&1)
        [ "$got" = "$want" ] || { echo "FAIL no-self-host: $n $f through clang prints '$got' (want '$want')"; fail=1; }
    done
    if [ $s = r ]; then
        "$c" -q --no-self-host -A android -o "$W/$s-and" "$W/p.xc" > "$W/e" 2>&1 && { echo "FAIL no-self-host: $n linked android through the NDK"; fail=1; }
        grep -q 'do not go through the NDK' "$W/e" || { echo "FAIL no-self-host: $n android: $(head -c 200 "$W/e")"; fail=1; }
        continue
    fi
    # Android through the NDK's clang (#31): the in-house unit as one object,
    # an executable and an APK. Run where a device or emulator is attached.
    [ -n "$NDK" ] || { echo "no-self-host: android skipped (no NDK)"; continue; }
    "$c" -q -O2 --no-self-host -A android -o "$W/and" "$W/p.xc" > "$W/e" 2>&1 \
        || { echo "FAIL no-self-host: $n android does not link through the NDK: $(head -c 300 "$W/e")"; fail=1; continue; }
    "$c" -q -O2 --no-self-host -A android --emit-apk -o "$W/nshapk.apk" "$W/p.xc" > "$W/e" 2>&1 \
        || { echo "FAIL no-self-host: $n android APK does not link through the NDK: $(head -c 300 "$W/e")"; fail=1; continue; }
    if [ -n "$ADB" ] && [ "$("$ADB" get-state 2>/dev/null)" = device ]; then
        "$ADB" push -q "$W/and" /data/local/tmp/xc-nsh > /dev/null
        got=$("$ADB" shell 'chmod 755 /data/local/tmp/xc-nsh; /data/local/tmp/xc-nsh; rm -f /data/local/tmp/xc-nsh' | tr -d '\r')
        [ "$got" = "$want" ] || { echo "FAIL no-self-host: $n android through the NDK prints '$got' (want '$want')"; fail=1; }
        PKG=org.compile_xc.nshapk
        "$ADB" uninstall $PKG > /dev/null 2>&1
        if "$ADB" install -r "$W/nshapk.apk" > /dev/null 2>&1; then
            "$ADB" logcat -c
            "$ADB" shell am start -n "$PKG/android.app.NativeActivity" > /dev/null 2>&1
            sleep 3
            got=$("$ADB" logcat -s xcapp -d | sed 's/^.*xcapp *: //' | grep -v '^=== xc \(start\|finished\) ===$' \
                  | grep -v '^--------- beginning' | tr -d '\r' | sed '/^$/d')
            "$ADB" uninstall $PKG > /dev/null 2>&1
            [ "$got" = "$want" ] || { echo "FAIL no-self-host: $n the NDK-linked APK logs '$got' (want '$want')"; fail=1; }
        else
            echo "FAIL no-self-host: $n the NDK-linked APK does not install"; fail=1
        fi
    else
        echo "no-self-host: android built, not run (no device)"
    fi
done
[ $fail = 0 ] && echo "no-self-host: ok"
exit $fail
