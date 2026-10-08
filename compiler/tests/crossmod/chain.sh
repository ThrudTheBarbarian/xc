#!/bin/bash
# chain.sh — a library that subclasses another library's class.
#
#   bash tests/crossmod/chain.sh
#
# chainbase.xc is a library with class Base (roots f, g). chainsub.xc is a
# second library that imports it and declares Sub : Base, overriding f and
# adding a root h. chainclient.xc imports both and calls a Sub through each.
# chainuse.xc is a third library that uses the first only inside its bodies
# and has startup code (a designable class's load-time constructor) that
# calls into the first. chainrev.xc imports it before the first library, and
# chainuseonly.xc imports it alone.
#
# Base's slots reach the second library as adopted numbers from the first
# library's interface. Its per-class numbering sized Base as its parent without
# them, so Sub's new root h took a slot of Base's (Base.f on arm64, x86_64 and
# arm9, where the app printed base=702, want 502).
#
# On every target:
#   - the slot map: Sub's vtable in the second library's IR holds Sub.f and
#     Base.g where Base's vtable in the first library holds Base.f and Base.g,
#     and Sub.h in the slot after (xcc-xc; xcc does not forward --emit-ir);
#   - the second library's assembly is the same from both compilers (on arm9,
#     both libraries' .so files, since the drivers' -S text differs in form).
# Run as well:
#   arm64   a lib x app compiler matrix, built and run here (macOS arm64 host).
#           The third library had no LC_LOAD_DYLIB for the first and bound
#           its imports by flat lookup, so for chainuseonly nothing loaded
#           the first (dyld: symbol not found '_UXNib$booted'). It now loads
#           it, and its imports from it are bound to it
#   wasm32  the same matrix under node. The second library's vtable words
#           for Base$vtbl, Base$description and Base$g name the first
#           library's symbols; they were left 0, so b.g() was a null call.
#           The loader loaded only the libraries the app names, so
#           chainuseonly failed at instantiation ("ChainBase": module is not
#           an object), and it relocated them in the app's import order, so
#           chainrev's startup code called through the first library's
#           vtable before it was filled (null function). ChainU.many frees
#           a `new Base[N]` made in the third library: each element runs
#           the first library's Base$dealloc
#   x86_64  the three libraries, chainclient and chainmany on $XTC_X86_HOST /
#           $XTC_LINUX_HOST. Those vtable words are R_X86_64_64 relocations
#           against the first library's symbols; the second library did not
#           link before they were. chainmany calls ChainU.many only: the
#           third library takes the address of the imported Base$dealloc
#           through the GOT, and did not link before it did. chainrev and
#           chainuseonly as well: the third library had no DT_NEEDED for the
#           first (undefined symbol UXNib$booted), and its load-time
#           constructor never ran (boot=0). It now records the first, and
#           registers its constructor table at load for the program's _start
#           to run, dependencies first
#   win64   the same matrix under wine. The second library's vtable words
#           name the first library's symbols and are filled at load from its
#           export table (pseudo-relocations), and chainrev and chainuseonly
#           run the third library's constructor from its DllMain
#   android the libraries and apps from both compilers, compared byte for
#           byte, and run over adb when a device or emulator is up. An
#           android .so had no interface, so nothing could import it, and no
#           image recorded an imported library as DT_NEEDED
# Not run:
#   arm9    running needs the loader tree and qemu
XC_PLAT=${XC_PLAT:-$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )}
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="${XCC_BIN:-$ROOT/bin/$XC_PLAT}"; [ -d "$BIN" ] || BIN="$ROOT/bin/linux"
T="$ROOT/tests/crossmod"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

WANT_chainclient=$'base=502\nsub=27\napp=705'
WANT_chainrev=$'boot=102\nmany=4\nbase=102'
WANT_chainuseonly=$'boot=102\nmany=3'
WANT_chainmany=$'many=4\nmany=2'

fail=0
bad() { echo "FAIL  $*"; fail=$((fail+1)); }

# flags <target> — the arm9 standard library needs the sysroot's libc.so.
flags() { [ "$1" = arm9 ] && [ -n "${XTC_ARM9_SYSROOT:-}" ] && echo "-L $XTC_ARM9_SYSROOT"; }

# lib <target> <compiler> <dir> <out> <src> [flags] — one library, in <dir>.
lib() {
    local a=$1 c=$2 d=$3 out=$4 src=$5; shift 5
    mkdir -p "$d"
    ( cd "$d" && "$BIN/$c" --emit-lib -A "$a" -H "$ROOT" -q -L . $(flags "$a") "$@" -o "$out" "$T/$src.xc" )
}
samefiles() {  # <dir1> <dir2> <file>...
    local d1=$1 d2=$2; shift 2
    for f in "$@"; do cmp -s "$d1/$f" "$d2/$f" || return 1; done
}
# vtable <ir> <class> — the class's vtable entries, one per line.
vtable() {
    grep "^  symbol $2\\\$vtbl: vtable \[" "$1" | sed 's/.*\[//; s/\].*//' | tr -d ' ' | tr ',' '\n'
}

# check <target> <ext> — the slot map and the two compilers' assembly.
check() {
    local a=$1 x=$2 c d base sub
    for c in xcc xcc-xc; do
        d="$TMP/$a/$c"; mkdir -p "$d"
        lib "$a" "$c" "$d" "libChainBase$x" chainbase 2>"$d.err" \
            || { bad "$a: $c could not build the first library"; sed 's/^/        /' "$d.err" | head -5; return; }
        lib "$a" "$c" "$d" sub.s chainsub -S 2>"$d.err" \
            || { bad "$a: $c could not compile the second library"; sed 's/^/        /' "$d.err" | head -5; return; }
        # arm9: the two drivers' -S text differs in form, so compare the .so.
        if [ "$a" = arm9 ]; then
            lib "$a" "$c" "$d" libChainSub.so chainsub 2>"$d.err" \
                || { bad "$a: $c could not build the second library"; sed 's/^/        /' "$d.err" | head -5; return; }
        fi
    done
    if [ "$a" = arm9 ]; then
        samefiles "$TMP/$a/xcc" "$TMP/$a/xcc-xc" libChainBase.so libChainSub.so \
            || bad "$a: the two compilers' libraries differ"
    else
        cmp -s "$TMP/$a/xcc/sub.s" "$TMP/$a/xcc-xc/sub.s" || bad "$a: the two compilers' second library differs"
    fi
    d="$TMP/$a/xcc-xc"
    lib "$a" xcc-xc "$d" base.s chainbase -S --emit-ir-opt 2>"$d/base.ir" &&
    lib "$a" xcc-xc "$d" sub.s chainsub -S --emit-ir-opt 2>"$d/sub.ir" \
        || { bad "$a: xcc-xc could not print the libraries' IR"; return; }
    base=$(vtable "$d/base.ir" Base | awk '$0=="Base$f"||$0=="Base$g"{print NR": "$0; last=NR} END{print last+1": Sub$h"}' | sed 's/Base\$f/Sub$f/')
    sub=$(vtable "$d/sub.ir" Sub | awk '$0=="Sub$f"||$0=="Base$g"||$0=="Sub$h"{print NR": "$0}')
    if [ -z "$sub" ] || [ "$sub" != "$base" ]; then
        bad "$a: Sub's slots in the second library, want:"
        echo "$base" | sed 's/^/        /'; echo "      got:"; echo "$sub" | sed 's/^/        /'
    fi
}

for spec in arm64:.dylib x86_64:.so win64:.dll arm9:.so wasm32:; do
    a=${spec%%:*}; x=${spec#*:}
    before=$fail
    check "$a" "$x"
    [ $fail = $before ] && echo "PASS  $a: Sub's slot map, and the two compilers agree"
done

# arm9: a library's load-time constructor reaches the loader. UsePanel's
# `outlet` gives libChainUse one, and the XTOS loader runs a dependency's
# DT_INIT_ARRAY when it loads it, so the tag has to be there: the words used
# to sit in .data unlabelled and nothing ran them. Running it needs the
# library in the loader's romfs (tests/crossmod/run.sh rebuilds that), so
# here it is built by both compilers, compared, and read.
if [ -n "${XTC_ARM9_SYSROOT:-}" ]; then
    before=$fail
    RE=$(command -v arm-none-eabi-readelf || command -v llvm-readelf || command -v readelf)
    for c in xcc xcc-xc; do
        d="$TMP/arm9/$c"
        lib arm9 "$c" "$d" libChainUse.so chainuse 2>"$d.use.err" \
            || { bad "arm9: $c could not build libChainUse"; sed 's/^/        /' "$d.use.err" | head -5; }
    done
    samefiles "$TMP/arm9/xcc" "$TMP/arm9/xcc-xc" libChainUse.so \
        || bad "arm9: the two compilers' libChainUse differs"
    if [ -n "$RE" ]; then
        "$RE" -d "$TMP/arm9/xcc-xc/libChainUse.so" 2>/dev/null | grep -q 'INIT_ARRAY' \
            || bad "arm9: libChainUse.so has no DT_INIT_ARRAY, so its constructor never runs"
        [ $fail = $before ] && echo "PASS  arm9: libChainUse carries DT_INIT_ARRAY, and the two compilers agree"
    else
        echo "SKIP  arm9: no readelf to read libChainUse's dynamic section (built and compared only)"
    fi
fi

# runmatrix <target> <ext> <runner> <libs> <app>... — the libraries (<libs>,
# e.g. "Base Sub") from each compiler, and each app from each compiler
# against each set, built and run.
runmatrix() {
    local a=$1 x=$2 run=$3 libs=$4 L A d got app want l ok
    shift 4
    for L in xcc xcc-xc; do
        d="$TMP/run-$a/lib-$L"; mkdir -p "$d"; ok=1
        for l in $libs; do
            lib "$a" "$L" "$d" "libChain$l$x" "chain$(echo "$l" | tr 'A-Z' 'a-z')" 2>>"$d.err" || ok=0
        done
        [ $ok = 1 ] || { bad "$a: $L could not build the libraries"; sed 's/^/        /' "$d.err" | head -5; }
    done
    samefiles "$TMP/run-$a/lib-xcc" "$TMP/run-$a/lib-xcc-xc" $(ls "$TMP/run-$a/lib-xcc") \
        || bad "$a: the two compilers' libraries differ"
    for L in xcc xcc-xc; do
        for A in xcc xcc-xc; do
            for app in "$@"; do
                d="$TMP/run-$a/$L-$A-$app"
                mkdir -p "$d"; cp "$TMP/run-$a/lib-$L"/* "$d/"
                ( cd "$d" && "$BIN/$A" -A "$a" -H "$ROOT" -q -L . -o "$app" "$T/$app.xc" ) 2>"$d/err" \
                    || { bad "$a lib=$L app=$A $app: the app did not build"; continue; }
                got=$($run "$d" "$app" 2>&1)
                want=WANT_$app
                [ "$got" = "${!want}" ] || { bad "$a lib=$L app=$A $app:"; echo "$got" | head -5 | sed 's/^/        /'; }
            done
        done
        # win64 links every image in-house in both drivers, so the programs
        # must agree byte for byte as the libraries do.
        if [ "$a" = win64 ]; then
            for app in "$@"; do
                cmp -s "$TMP/run-$a/$L-xcc-$app/$app" "$TMP/run-$a/$L-xcc-xc-$app/$app" \
                    || bad "$a lib=$L: the two compilers' $app differs"
            done
        fi
    done
}
run_native() { ( cd "$1" && ./"$2" ); }
run_node()   { ( cd "$1" && node "$2.js" ); }
# run_wine <dir> <prog> — under wine, with the crash dialog off: a program that
# faults must fail the test, not open a window.
run_wine() { ( cd "$1" && WINEDLLOVERRIDES="winedbg.exe=d" WINEDEBUG=-all wine "./$2" 2>/dev/null | tr -d '\r' ); }
run_x86() {
    ssh "$HOST" "rm -rf $RD && mkdir -p $RD" </dev/null
    scp -q "$1/$2" "$1"/*.so "$HOST:$RD/"
    ssh "$HOST" "cd $RD && ./$2" </dev/null
}

before=$fail
case "$(uname -s)-$(uname -m)" in
    Darwin-arm64)
        runmatrix arm64 .dylib run_native "Base Sub Use" chainclient chainrev chainuseonly
        [ $fail = $before ] && echo "PASS  arm64: run, lib x app compiler matrix" ;;
    *)  echo "SKIP  arm64 run: needs a macOS arm64 host" ;;
esac

before=$fail
if command -v node >/dev/null 2>&1; then
    runmatrix wasm32 "" run_node "Base Sub Use" chainclient chainrev chainuseonly
    [ $fail = $before ] && echo "PASS  wasm32: run under node, lib x app compiler matrix"
else
    echo "SKIP  wasm32 run: no node"
fi

before=$fail
HOST=${XTC_X86_HOST:-${XTC_LINUX_HOST:-}}
if [ -n "$HOST" ] && ssh -o ConnectTimeout=8 -o BatchMode=yes "$HOST" true 2>/dev/null; then
    RD=/tmp/xc-chain-$$
    runmatrix x86_64 .so run_x86 "Base Sub Use" chainclient chainmany chainrev chainuseonly
    ssh "$HOST" "rm -rf $RD" </dev/null
    [ $fail = $before ] && echo "PASS  x86_64: run on $HOST, lib x app compiler matrix"
else
    echo "SKIP  x86_64 run: no x86-64 host reachable"
fi

before=$fail
if command -v wine >/dev/null 2>&1; then
    runmatrix win64 .dll run_wine "Base Sub Use" chainclient chainmany chainrev chainuseonly
    [ $fail = $before ] && echo "PASS  win64: run under wine, lib x app compiler matrix"
else
    echo "SKIP  win64 run: no wine"
fi

# ── android: the libraries import each other (bug 460) ────────────────────
# An android .so carried no interface, so `#import <ChainBase>` failed in the
# client, and neither android link recorded an imported library as DT_NEEDED.
# Both compilers build the three libraries and the apps; the files must agree
# byte for byte (both links are in-house), each library and app must name
# what it imports, and the apps run over adb when a device or emulator is up.
# needed <elf> — the DT_NEEDED names of an ELF64 image, one per line.
needed() {
    python3 - "$1" <<'PY'
import struct, sys
b = open(sys.argv[1], "rb").read()
shoff, = struct.unpack_from("<Q", b, 0x28)
shent, shnum = struct.unpack_from("<HH", b, 0x3a)
secs = [struct.unpack_from("<IIQQQQIIQQ", b, shoff + i * shent) for i in range(shnum)]
for s in secs:
    if s[1] != 6:  # SHT_DYNAMIC
        continue
    stroff = secs[s[6]][4]
    for o in range(s[4], s[4] + s[5], 16):
        tag, val = struct.unpack_from("<qQ", b, o)
        if tag == 0:
            break
        if tag == 1:
            print(b[stroff + val:b.index(b"\0", stroff + val)].decode())
PY
}
: "${ANDROID_HOME:=$HOME/Library/Android/sdk}"
ADB="$ANDROID_HOME/platform-tools/adb"
run_adb() {
    local rd=/data/local/tmp/xc-chain-$$
    "$ADB" shell "rm -rf $rd && mkdir -p $rd" </dev/null >/dev/null
    "$ADB" push "$1"/*.so "$1/$2" "$rd/" >/dev/null 2>&1
    "$ADB" shell "cd $rd && LD_LIBRARY_PATH=. ./$2; s=\$?; rm -rf $rd; exit \$s" </dev/null 2>&1 | tr -d '\r'; return ${PIPESTATUS[0]}
}
before=$fail
for c in xcc xcc-xc; do
    d="$TMP/android/$c"; mkdir -p "$d"
    for l in Base Sub Use; do
        lib android "$c" "$d" "libChain$l.so" "chain$(echo "$l" | tr 'A-Z' 'a-z')" 2>>"$d.err" \
            || bad "android: $c could not build libChain$l.so"
    done
    for app in chainclient chainmany chainrev chainuseonly; do
        ( cd "$d" && "$BIN/$c" -A android -H "$ROOT" -q -L . -o "$app" "$T/$app.xc" ) 2>>"$d.err" \
            || bad "android: $c could not build $app"
    done
    [ -s "$d.err" ] && sed 's/^/        /' "$d.err" | head -5
done
samefiles "$TMP/android/xcc" "$TMP/android/xcc-xc" libChainBase.so libChainSub.so libChainUse.so \
    chainclient chainmany chainrev chainuseonly \
    || bad "android: the two compilers' files differ"
d="$TMP/android/xcc-xc"
for pair in libChainSub.so:libChainBase.so libChainUse.so:libChainBase.so \
            chainclient:libChainSub.so chainuseonly:libChainUse.so chainrev:libChainBase.so; do
    needed "$d/${pair%%:*}" 2>/dev/null | grep -qx "${pair#*:}" \
        || bad "android: ${pair%%:*} has no DT_NEEDED for ${pair#*:}"
done
[ $fail = $before ] && echo "PASS  android: libraries import each other, and the two compilers agree"

# ── android: the runtime defines what the macOS runtime defines (bug 634) ──
# rt-android.s is generated from the same rt.c as rt-macos.s and checked in; a
# function added to rt.c and regenerated for macOS only is undefined on android,
# and the app fails at dlopen ("cannot locate symbol _xtc_new_i64").
before=$fail
miss=$(comm -23 <(grep -o '^__xtc_[A-Za-z0-9_]*:' "$ROOT/support/arm64/runtime/rt-macos.s" | sed 's/^_//; s/:$//' | sort -u) \
               <(grep -o '^_xtc_[A-Za-z0-9_]*:' "$ROOT/support/arm64/runtime/rt-android.s" | sed 's/:$//' | sort -u))
[ -z "$miss" ] || bad "android: rt-android.s lacks runtime functions rt-macos.s defines: $(echo $miss | cut -c1-200)"
[ $fail = $before ] && echo "PASS  android: the runtime defines every function the macOS runtime defines"

# ── android: an APK names and carries the libraries its program imports (bug 635)
# The `--emit-apk` payload recorded no DT_NEEDED for an imported library, so
# dlopen could not resolve its symbols; and `--with-lib` stored a file under
# its own name when its soname differed (an installed libChainBase-1-0.so is
# loaded as libChainBase.so). The payload and the stored library must agree
# between the compilers byte for byte.
before=$fail
for c in xcc xcc-xc; do
    ad="$TMP/apk/$c"; mkdir -p "$ad/v"   # not `d`: the run step below reads it
    cp "$TMP/android/$c/libChainBase.so" "$ad/v/libChainBase-1-0.so"
    ( cd "$TMP/android/$c" && "$BIN/$c" -A android --emit-apk -H "$ROOT" -q -L . \
        --with-lib "$ad/v/libChainBase-1-0.so" -o "$ad/chainrev.apk" "$T/chainrev.xc" ) 2>"$ad.err" \
        || { bad "android apk: $c could not build chainrev.apk"; sed 's/^/        /' "$ad.err" | head -5; continue; }
    ( cd "$ad" && unzip -qo chainrev.apk 'lib/arm64-v8a/*' ) 2>/dev/null
    needed "$ad/lib/arm64-v8a/libchainrev.so" 2>/dev/null | grep -qx libChainBase.so \
        || bad "android apk: $c's payload has no DT_NEEDED for libChainBase.so"
    [ -f "$ad/lib/arm64-v8a/libChainBase.so" ] \
        || bad "android apk: $c stored the versioned --with-lib under its file name, not its soname"
done
samefiles "$TMP/apk/xcc/lib/arm64-v8a" "$TMP/apk/xcc-xc/lib/arm64-v8a" libchainrev.so libChainBase.so \
    || bad "android apk: the two compilers' payloads differ"
[ $fail = $before ] && echo "PASS  android: an APK names and carries the libraries its program imports"
before=$fail
if [ -x "$ADB" ] && [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; then
    # The printed NUMBERS are compared, not just the labels. They used to be
    # skipped: Stdio.printf's variadic arguments came out wrong on android in
    # any program, library or not (bug 547 — `-A android` switches the code
    # generator to AAPCS64, and an xc-BODIED variadic reads its tail from a
    # stack va_list, so the arguments had to stay on the stack rather than
    # follow the C rule into x0-x7 and the vector registers). Every app here
    # prints its numbers through that call, so this is the guard: an argument
    # placed for the wrong reader is a failure, not a comment.
    for app in chainclient chainmany chainrev chainuseonly; do
        got=$(run_adb "$d" "$app"; echo "rc=$?")
        want=WANT_$app
        [ "$got" = "$(printf '%s\nrc=0\n' "${!want}")" ] \
            || { bad "android $app:"; echo "$got" | head -5 | sed 's/^/        /'; }
    done
    [ $fail = $before ] && echo "PASS  android: run over adb"
else
    echo "SKIP  android run: no device or emulator visible to adb"
fi

# ── ios-sim: a library is stamped for the simulator and carries the shim ─────
# An `-A ios-sim --emit-lib` library carried LC_BUILD_VERSION platform 1
# (macOS) and dyld refused to load it (bug 633); and it left out the iOS shim,
# so its `_xt_ios_log` was "symbol not found in flat namespace" at load (bug
# 634). Both compilers must agree on the bytes.
if xcrun --sdk iphonesimulator --show-sdk-path >/dev/null 2>&1; then
    before=$fail
    mkdir -p "$TMP/ios-sim"
    for c in xcc xcc-xc; do
        d="$TMP/ios-sim/$c"
        lib ios-sim "$c" "$d" libChainBase.dylib chainbase 2>"$d.err" \
            || { bad "ios-sim: $c could not build libChainBase.dylib"; sed 's/^/        /' "$d.err" | head -5; continue; }
        plat=$(otool -l "$d/libChainBase.dylib" | grep -A2 LC_BUILD_VERSION | awk '/platform/ {print $2}')
        [ "$plat" = 7 ] || bad "ios-sim: $c's library says platform ${plat:-none}, not 7 (iOS simulator)"
        nm "$d/libChainBase.dylib" 2>/dev/null | grep -q ' [Tt] __xt_ios_log$' \
            || bad "ios-sim: $c's library does not carry the iOS shim (__xt_ios_log)"
    done
    samefiles "$TMP/ios-sim/xcc" "$TMP/ios-sim/xcc-xc" libChainBase.dylib \
        || bad "ios-sim: the two compilers' libraries differ"
    [ $fail = $before ] && echo "PASS  ios-sim: a library is stamped for the simulator and carries the shim"
else
    echo "SKIP  ios-sim: no iPhoneSimulator SDK"
fi

# ── arm64: a zero-initialised global takes no room in the file ───────────────
# A 32 MB `u32 big[8000000];` gave a 32 MB executable (bug 642): the COMMON
# storage was emitted as data bytes. It is a __DATA,__bss zero-fill section
# now, in memory only, so the file is small and the two compilers agree.
if [ "$XC_PLAT" = osx ]; then
    before=$fail
    mkdir -p "$TMP/zerobig"
    for c in xcc xcc-xc; do
        "$BIN/$c" -A arm64 -H "$ROOT" -q -o "$TMP/zerobig/$c" "$T/zerobig.xc" 2>"$TMP/zerobig/$c.err" \
            || { bad "zerobig: $c could not build it"; sed 's/^/        /' "$TMP/zerobig/$c.err" | head -5; continue; }
        sz=$(stat -f %z "$TMP/zerobig/$c")
        [ "$sz" -lt 4000000 ] || bad "zerobig: $c's executable is $sz bytes; the zero array should not be in the file"
        otool -l "$TMP/zerobig/$c" | grep -q 'sectname __bss' || bad "zerobig: $c's executable has no __bss section"
        out=$("$TMP/zerobig/$c" 2>&1)
        [ "$out" = "1 0 7 2" ] || bad "zerobig: $c's program printed '$out', not '1 0 7 2'"
    done
    cmp -s "$TMP/zerobig/xcc" "$TMP/zerobig/xcc-xc" || bad "zerobig: the two compilers' executables differ"
    [ $fail = $before ] && echo "PASS  arm64: a zero-initialised global takes no room in the file"
fi

echo "--- chain: $fail failing ---"
[ "$fail" = 0 ]
