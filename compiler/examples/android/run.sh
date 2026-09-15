#!/bin/bash
# The Android target, both shapes, against the macOS arm64 oracle.
#
#   1. `-A android`                 → aarch64 ELF PIE, IN-HOUSE (no NDK clang),
#                                     run over `adb shell`
#   2. `-A android --no-self-host`  → the same, linked through the NDK clang;
#                                     both paths must agree with the oracle
#   3. `-A android --emit-apk`      → an installable NativeActivity APK, launched
#                                     with `am start` and read back from logcat.
#                                     In-house as well; the SDK is still needed
#                                     for the container and the signature.
#
# Nothing else RUNS the Android output: the corpus builds for arm64 and xt6502
# only, and no differential executes anything. A missing emulator is a loud
# SKIP, never a pass.
#
# Needs: $ANDROID_HOME (SDK + an ndk/<ver>), and a booted arm64 emulator or
# device visible to adb.
set -u
cd "$(dirname "$0")/../.." || exit 1
BIN=bin/osx; [ -d "$BIN" ] || BIN=bin/linux
: "${ANDROID_HOME:=$HOME/Library/Android/sdk}"
export ANDROID_HOME
ADB="$ANDROID_HOME/platform-tools/adb"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail=0

# The fixtures deliberately span what the port could plausibly break: ARC
# retain/release traffic, a typed collection unboxing primitives, and 64-bit
# arithmetic (the widest thing the arm64 backend emits).
# Chosen for what the port could plausibly break: ARC retain/release traffic, a
# typed collection unboxing primitives, 64-bit arithmetic (the widest thing the
# arm64 backend emits), the C-variadic ABI (Android is AAPCS64 where macOS is
# Darwin — the one place the two disagree about argument placement), buffered
# stdio surviving a return from main, and threads (whose atomics are an
# ldaxr/stlxr pair on Android's LSE-less baseline).
FIXTURES="arc_param arc_nested_chain arc_global_array collection_unbox_contexts
          int64_ops int64_arith cvariadic_call exit_flush threads_mutex_counter
          threads_atomic_tls"

if [ ! -x "$ADB" ]; then
    echo "  SKIP android: no adb at $ADB (set ANDROID_HOME)"; exit 0
fi
if [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" != "1" ]; then
    echo "  SKIP android: no booted device/emulator visible to adb"
    echo "         start one with: \$ANDROID_HOME/emulator/emulator -avd <avd> -no-window"
    exit 0
fi

for n in $FIXTURES; do
    SRC=tests/fixtures/$n.xc
    # The oracle is the SAME program on macOS arm64 — same backend, same IR,
    # only the link differs. A stale expected.out cannot mask a port bug.
    if ! "$BIN/xcc" -A arm64 -H . -o "$TMP/mac" "$SRC" >"$TMP/log" 2>&1; then
        echo "  SKIP $n: arm64 oracle will not build"; continue
    fi
    "$TMP/mac" > "$TMP/want" 2>&1

    # ── 1+2. bare ELF over adb shell, both link paths ─────────────────────
    # The in-house link and the clang link are compared SEPARATELY against the
    # oracle rather than against each other: two paths agreeing on the wrong
    # answer is exactly what a differential between them cannot see.
    for mode in selfhost clang; do
        [ "$mode" = clang ] && FLAG=--no-self-host || FLAG=
        if ! "$BIN/xcc" -A android $FLAG -H . -o "$TMP/elf" "$SRC" >"$TMP/log" 2>&1; then
            echo "  FAIL $n elf/$mode: compile"; sed 's/^/    /' "$TMP/log"; fail=1; continue
        fi
        "$ADB" push "$TMP/elf" /data/local/tmp/xcrun >/dev/null 2>&1
        "$ADB" shell chmod 755 /data/local/tmp/xcrun >/dev/null 2>&1
        "$ADB" shell /data/local/tmp/xcrun 2>&1 | tr -d '\r' > "$TMP/got"
        if diff -q "$TMP/got" "$TMP/want" >/dev/null; then echo "  PASS $n elf/$mode"
        else echo "  FAIL $n elf/$mode"; diff "$TMP/want" "$TMP/got" | sed 's/^/    /'; fail=1; fi
    done

    # ── 2. NativeActivity APK, read back from logcat ──────────────────────
    if ! "$BIN/xcc" -A android --emit-apk -H . -o "$TMP/$n.apk" "$SRC" >"$TMP/log" 2>&1; then
        echo "  FAIL $n apk: build"; sed 's/^/    /' "$TMP/log"; fail=1; continue
    fi
    PKG=org.compile_xc.$(echo "$n" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9]/_/g')
    "$ADB" uninstall "$PKG" >/dev/null 2>&1
    if ! "$ADB" install -r "$TMP/$n.apk" >/dev/null 2>&1; then
        echo "  FAIL $n apk: install"; fail=1; continue
    fi
    "$ADB" logcat -c
    "$ADB" shell am start -n "$PKG/android.app.NativeActivity" >/dev/null 2>&1
    sleep 3
    "$ADB" logcat -s xcapp -d | sed 's/^.*xcapp *: //' \
        | grep -v '^=== xc \(start\|finished\) ===$' | grep -v '^--------- beginning' \
        | tr -d '\r' | sed '/^$/d' > "$TMP/gotapk"
    sed '/^$/d' "$TMP/want" > "$TMP/wantapk"
    "$ADB" uninstall "$PKG" >/dev/null 2>&1
    if diff -q "$TMP/gotapk" "$TMP/wantapk" >/dev/null; then echo "  PASS $n apk"
    else echo "  FAIL $n apk"; diff "$TMP/wantapk" "$TMP/gotapk" | sed 's/^/    /'; fail=1; fi
done

# ── 4. the writer's OTHER shape: an in-house .so, dlopen'd by an in-house PIE.
# Nothing in the driver emits one yet (the APK's payload is linked by the NDK
# clang because its NativeActivity glue is NDK C source), so without this the
# `.so` half of XTElfArm64Writer would ship unexercised. It is also the only
# check that the section header table is right: the kernel's exec path reads
# program headers only and never looks at it, but bionic's dlopen validates it.
# The whole point of the APK work: build one with NO Android SDK, NDK or JDK
# visible at all. `env -u` is the check — a path defaulted to elsewhere in the
# code would still be found, so the variables are removed rather than blanked
# and the package is INSTALLED, not just written.
if env -u ANDROID_HOME -u ANDROID_SDK_ROOT -u ANDROID_NDK_HOME \
       "$BIN/xcc" -A android --emit-apk -H . -o "$TMP/nosdk.apk" \
       tests/fixtures/arc_param.xc >"$TMP/log" 2>&1; then
    PKG=org.compile_xc.nosdk
    "$ADB" uninstall "$PKG" >/dev/null 2>&1
    if "$ADB" install -r "$TMP/nosdk.apk" >/dev/null 2>&1; then
        echo "  PASS apk with NO sdk/ndk/jdk (installs)"
        "$ADB" uninstall "$PKG" >/dev/null 2>&1
    else
        echo "  FAIL apk with NO sdk/ndk/jdk: install refused"; fail=1
    fi
else
    echo "  FAIL apk with NO sdk/ndk/jdk: build"; sed 's/^/    /' "$TMP/log"; fail=1
fi

# uxkit/031: an optional committed classes.dex rides at the archive ROOT, and
# `android:hasCode` follows its presence. Both halves are checked, because the
# failure the spike hit was hasCode="false" with a dex present — ART then skips
# classes.dex entirely, which looks exactly like a dex that failed to load.
# The dex is opaque to the writer (it stores bytes), so a stand-in is enough
# here; what is being checked is the packaging, not the dex.
printf 'dex\n035\0' > "$TMP/stub.dex"
head -c 900 /dev/zero >> "$TMP/stub.dex"
for want in true false; do
    # No empty-array expansion: this runs under `set -u`, and bash 3.2 (which is
    # what macOS ships) treats "${arr[@]}" on an EMPTY array as unbound and
    # aborts the whole script. That is how it aborted here — silently, after
    # printing a PASS, so everything below never ran and the run still looked
    # clean. Two explicit branches cost a duplicated line and cannot do that.
    if [ "$want" = true ]; then
        "$BIN/xcc" -A android --emit-apk -H . --with-dex "$TMP/stub.dex" \
            -o "$TMP/dex-$want.apk" tests/fixtures/arc_param.xc >"$TMP/log" 2>&1
    else
        "$BIN/xcc" -A android --emit-apk -H . \
            -o "$TMP/dex-$want.apk" tests/fixtures/arc_param.xc >"$TMP/log" 2>&1
    fi
    if [ $? -eq 0 ]; then
        gotEntry=no; unzip -l "$TMP/dex-$want.apk" 2>/dev/null | grep -q 'classes\.dex' && gotEntry=yes
        wantEntry=no; [ "$want" = true ] && wantEntry=yes
        if [ "$gotEntry" = "$wantEntry" ]; then
            echo "  PASS apk classes.dex entry ($wantEntry)"
        else
            echo "  FAIL apk classes.dex entry: wanted $wantEntry got $gotEntry"; fail=1
        fi
        # hasCode lives in the BINARY manifest, so it is read back rather than
        # assumed. aapt2 is a verifier here, never part of the build.
        AAPT2=$(ls -d "$HOME"/Library/Android/sdk/build-tools/*/aapt2 2>/dev/null | tail -1)
        if [ -n "$AAPT2" ] && [ -x "$AAPT2" ]; then
            got=$("$AAPT2" dump xmltree "$TMP/dex-$want.apk" --file AndroidManifest.xml 2>/dev/null \
                  | sed -n 's/.*hasCode(0x[0-9a-f]*)=//p' | head -1)
            if [ "$got" = "$want" ]; then
                echo "  PASS apk manifest hasCode=$want"
            else
                echo "  FAIL apk manifest hasCode: wanted $want got '${got:-<none>}'"; fail=1
            fi
        else
            echo "  SKIP apk manifest hasCode=$want (no aapt2 to read it back)"
        fi
    else
        echo "  FAIL apk --with-dex build ($want)"; sed 's/^/    /' "$TMP/log"; fail=1
    fi
done

# uxkit/032: the driver's TWO-LIB arrangement in one xcc line. The NDK-built
# shim runs first (android.app.lib_name points at IT), stashes the activity and
# VM, loads the bridge dex, then dlopens the payload — and the payload must NAME
# the shim in DT_NEEDED, because bionic resolves a library's imports against its
# own local group only and does not honour RTLD_GLOBAL promotion of something
# already loaded. That NEEDED entry is what the gate's addneeded.py used to
# patch in after the fact.
#
# Any valid .so stands in for the shim here: the writer stores bytes, and what
# is under test is the packaging, not the shim's own code.
# The stand-in shim is the payload .so out of an APK this suite already built —
# a genuine android ELF. NOT `--emit-lib -A android`, which silently produces a
# Mach-O dylib for the host (filed separately); a gate must not be built on a
# broken path.
SHIMSRC="$TMP/gatelib.xc"; printf 'i32 gate_twice(i32 x) { return x + x; }\n' > "$SHIMSRC"
rm -rf "$TMP/shimsrc"; unzip -o -q "$TMP/dex-true.apk" 'lib/arm64-v8a/*' -d "$TMP/shimsrc" 2>/dev/null
cp "$TMP/shimsrc"/lib/arm64-v8a/*.so "$TMP/libUXAndroid.so" 2>/dev/null
if [ -s "$TMP/libUXAndroid.so" ] && \
   "$BIN/xcc" -A android --emit-apk -H . tests/fixtures/arc_param.xc \
        --needed libUXAndroid.so --with-lib "$TMP/libUXAndroid.so" \
        --lib-name UXAndroid --with-dex "$TMP/stub.dex" \
        -o "$TMP/twolib.apk" >>"$TMP/log" 2>&1; then
    ok=1
    unzip -l "$TMP/twolib.apk" 2>/dev/null | grep -q 'libUXAndroid\.so' \
        || { echo "  FAIL apk two-lib: shim not packaged"; ok=0; }
    AAPT2=$(ls -d "$HOME"/Library/Android/sdk/build-tools/*/aapt2 2>/dev/null | tail -1)
    if [ -n "$AAPT2" ] && [ -x "$AAPT2" ]; then
        got=$("$AAPT2" dump xmltree "$TMP/twolib.apk" --file AndroidManifest.xml 2>/dev/null \
              | grep -A1 'android.app.lib_name' | sed -n 's/.*value(0x[0-9a-f]*)="\([^"]*\)".*/\1/p' | head -1)
        [ "$got" = "UXAndroid" ] \
            || { echo "  FAIL apk two-lib: lib_name is '${got:-<none>}', wanted UXAndroid"; ok=0; }
    fi
    # DT_NEEDED, read with the NDK's own reader when there is one.
    RE=$(ls -d "$HOME"/Library/Android/sdk/ndk/*/toolchains/llvm/prebuilt/*/bin/llvm-readelf 2>/dev/null | tail -1)
    if [ -n "$RE" ] && [ -x "$RE" ]; then
        # The payload is named after the OUTPUT file, not the source, so it is
        # found by elimination rather than by a guessed name.
        rm -rf "$TMP/tl"; unzip -o -q "$TMP/twolib.apk" -d "$TMP/tl"
        payload=$(ls "$TMP/tl"/lib/arm64-v8a/*.so 2>/dev/null | grep -v libUXAndroid | head -1)
        if [ -z "$payload" ]; then
            echo "  FAIL apk two-lib: no payload .so in the package"; ok=0
        elif ! "$RE" -d "$payload" 2>/dev/null | grep -q 'NEEDED.*libUXAndroid\.so'; then
            echo "  FAIL apk two-lib: $(basename "$payload") has no DT_NEEDED libUXAndroid.so"; ok=0
        fi
    fi
    [ "$ok" = 1 ] && echo "  PASS apk two-lib (--needed + --with-lib + --lib-name)"
    [ "$ok" = 1 ] || fail=1
else
    echo "  FAIL apk two-lib: build"; sed 's/^/    /' "$TMP/log" | head -5; fail=1
fi

# Every entry must be aligned, not just the .so — `zipalign -c -p 4` failed on
# every package this writer produced until the manifest and dex were aligned too.
ZA=$(ls -d "$HOME"/Library/Android/sdk/build-tools/*/zipalign 2>/dev/null | tail -1)
if [ -n "$ZA" ] && [ -x "$ZA" ]; then
    if "$ZA" -c -p 4 "$TMP/twolib.apk" >/dev/null 2>&1; then
        echo "  PASS apk zipalign -c -p 4"
    else
        echo "  FAIL apk zipalign -c -p 4:"; "$ZA" -c -v -p 4 "$TMP/twolib.apk" 2>&1 | grep -vi 'OK$' | head -4; fail=1
    fi
fi

# Bug 067: `-A android --emit-lib` is a real ELF shared object — no glue, no
# crt, this module's API exported, a soname and the base DT_NEEDED set. It used
# to fall through to the HOST's Mach-O dylib path and write a Mach-O into a
# `.so`: the wrong file FORMAT for a target that cannot load one, under a name
# that said otherwise, and nothing downstream said so.
if "$BIN/xcc" -A android --emit-lib -H . -o "$TMP/libgate.so" "$SHIMSRC" \
        >"$TMP/log" 2>&1 && [ -s "$TMP/libgate.so" ]; then
    if file "$TMP/libgate.so" | grep -q 'ELF 64-bit.*shared object.*aarch64'; then
        RE=$(ls -d "$HOME"/Library/Android/sdk/ndk/*/toolchains/llvm/prebuilt/*/bin/llvm-readelf 2>/dev/null | tail -1)
        if [ -n "$RE" ] && [ -x "$RE" ]; then
            if "$RE" -d "$TMP/libgate.so" 2>/dev/null | grep -q 'SONAME.*libgate\.so'; then
                echo "  PASS android --emit-lib (ELF .so, soname libgate.so)"
            else
                echo "  FAIL android --emit-lib: no/!wrong SONAME"; fail=1
            fi
        else
            echo "  PASS android --emit-lib (ELF .so; no readelf to check the soname)"
        fi
    else
        echo "  FAIL android --emit-lib: not an aarch64 ELF shared object —"
        echo "       $(file "$TMP/libgate.so")"; fail=1
    fi
else
    echo "  FAIL android --emit-lib: build"; sed 's/^/    /' "$TMP/log" | head -5; fail=1
fi

# The APK's CLANG fallback, once. Every fixture above exercised the in-house
# .so; this keeps the other path from rotting unnoticed.
if "$BIN/xcc" -A android --emit-apk --no-self-host -H . -o "$TMP/fallback.apk" \
        tests/fixtures/arc_param.xc >"$TMP/log" 2>&1; then
    echo "  PASS apk clang-fallback link"
else
    echo "  FAIL apk clang-fallback link"; sed 's/^/    /' "$TMP/log"; fail=1
fi

LN="$BIN/xcc-ln-arm64"
if [ -x "$LN" ]; then
    cat > "$TMP/lib.s" <<'ASM'
.text
.globl greet
.p2align 2
greet:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    adrp x0, gmsg@PAGE
    add  x0, x0, gmsg@PAGEOFF
    bl puts
    ldp x29, x30, [sp], #16
    ret
.data
gmsg:
    .asciz "hello from an in-house aarch64 .so"
ASM
    cat > "$TMP/dl.s" <<'ASM'
.text
.globl main
.p2align 2
main:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x19, [sp, #16]
    adrp x0, sopath@PAGE
    add  x0, x0, sopath@PAGEOFF
    mov w1, #2                       // RTLD_NOW
    bl dlopen
    mov x19, x0
    cbz x19, Lfail
    mov x0, x19
    adrp x1, symname@PAGE
    add  x1, x1, symname@PAGEOFF
    bl dlsym
    cbz x0, Lfail
    blr x0
    mov w0, #0
    b Ldone
Lfail:
    adrp x0, failmsg@PAGE
    add  x0, x0, failmsg@PAGEOFF
    bl puts
    mov w0, #1
Ldone:
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret
.data
sopath:
    .asciz "/data/local/tmp/xclibgreet.so"
symname:
    .asciz "greet"
failmsg:
    .asciz "dlopen/dlsym FAILED"
ASM
    echo greet > "$TMP/exports"
    cat support/arm64/runtime/crt-android.s support/arm64/runtime/rt-android.s         "$TMP/dl.s" > "$TMP/dlall.s"
    if "$LN" --android so xclibgreet.so "$TMP/exports" libc.so "$TMP/lib.s" "$TMP/libgreet.so"        && "$LN" --android exe _start - libc.so,libm.so,libdl.so "$TMP/dlall.s" "$TMP/dl"; then
        "$ADB" push "$TMP/libgreet.so" /data/local/tmp/xclibgreet.so >/dev/null 2>&1
        "$ADB" push "$TMP/dl" /data/local/tmp/xcdl >/dev/null 2>&1
        "$ADB" shell chmod 755 /data/local/tmp/xcdl >/dev/null 2>&1
        "$ADB" shell /data/local/tmp/xcdl 2>&1 | tr -d '\r' > "$TMP/dlout"
        if grep -q "hello from an in-house aarch64 .so" "$TMP/dlout"; then
            echo "  PASS in-house .so, dlopen'd by an in-house PIE"
        else
            echo "  FAIL in-house .so"; sed 's/^/    /' "$TMP/dlout"; fail=1
        fi
        "$ADB" shell rm -f /data/local/tmp/xclibgreet.so /data/local/tmp/xcdl >/dev/null 2>&1
    else
        echo "  FAIL in-house .so: link"; fail=1
    fi
fi

"$ADB" shell rm -f /data/local/tmp/xcrun >/dev/null 2>&1
exit $fail
