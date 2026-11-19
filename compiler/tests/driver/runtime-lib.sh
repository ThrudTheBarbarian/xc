#!/bin/bash
# runtime-lib.sh — libRuntime (2026-11-03): the par runtime and the object
# runtime, prebuilt per target (make runtime-libs), which every program links.
#
#   1. Both compilers build the same libRuntime from Par.xc (--emit-runtime).
#   2. A lifted loop, a written par block and plain programs each link the
#      tree's libRuntime and print what a --no-runtime-lib build of the same
#      source prints; the lifted one compiles in under half the time.
#   3. A link that brings an xcc object (-Wl,x.o) keeps its runtime its own;
#      one that brings a C object or archive takes the library, and so does a
#      library linked with a C archive, whose clients then share one runtime
#      with it (#453: its own copy kept their arrays' spans from par).
#
# Needs the target's libRuntime built in this tree; says so and passes when
# it is not (the gate builds it first).
#
#   bash tests/driver/runtime-lib.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$([ "$(uname -s)" = Darwin ] && echo osx || echo linux)
REF=bin/$PLAT/xcc; XC=${XC:-bin/$PLAT/xcc-xc}
case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) ROW=arm64-macos; EXT=dylib ;;
    Linux-x86_64) ROW=x86_64-linux; EXT=so ;;
    Linux-aarch64) ROW=arm64-linux; EXT=so ;;
    *) echo "runtime-lib: skipped (no libRuntime row for this host)"; exit 0 ;;
esac
LIB=support/runtime-lib/$ROW/libRuntime.$EXT
[ -f "$LIB" ] || { echo "runtime-lib: skipped (no $LIB: make runtime-libs)"; exit 0; }
W=$(mktemp -d /tmp/runtime-lib.XXXX)
trap 'rm -rf "$W"' EXIT
fail=0
needs() { if [ "$PLAT" = osx ]; then otool -L "$1" | grep -c libRuntime; else readelf -d "$1" | grep -c 'NEEDED.*libRuntime'; fi; }
ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }

# 1. The library itself, by both compilers, under one name.
for c in "$REF" "$XC"; do
    [ -x "$c" ] || continue
    mkdir -p "$W/$(basename "$c")"
    "$c" -q -O2 -H . --par-style=cpu --emit-runtime support/generic/lib/Par.xc \
        -o "$W/$(basename "$c")/libRuntime.$EXT" || { echo "FAIL runtime-lib: $c --emit-runtime"; fail=1; }
done
if [ -f "$W/xcc/libRuntime.$EXT" ] && [ -f "$W/xcc-xc/libRuntime.$EXT" ] \
   && ! cmp -s "$W/xcc/libRuntime.$EXT" "$W/xcc-xc/libRuntime.$EXT"; then
    echo "FAIL runtime-lib: the two compilers' libRuntime differ"; fail=1
fi

# 2. Programs against the tree's library, and the same built without it.
# lifted: a loop --par-style=auto makes a block of (the fixtures' loops are
# small enough to stay loops).
cat > "$W/lifted.xc" <<'EOF'
#import "Stdio.xc"
#define N 1048576
float a[N];
i32 main(void)
    {
    for (u32 i = (u32)0; i < (u32)N; i++)
        a[i] = (float)i * 0.5f;
    Stdio.printf("%.1f\n", (double)a[N - 1]);
    return 0;
    }
EOF
for f in lifted vec_map_iota par_device_default addr_of_ivar; do
    src=tests/fixtures/$f.xc; [ "$f" = lifted ] && src=$W/lifted.xc
    s=$(ms); "$XC" -q -O2 -H . -o "$W/$f.lib" "$src" || { echo "FAIL runtime-lib: $f does not build"; fail=1; continue; }
    tl=$(( $(ms) - s ))
    s=$(ms); "$XC" -q -O2 -H . --no-runtime-lib -o "$W/$f.src" "$src" || { echo "FAIL runtime-lib: $f --no-runtime-lib"; fail=1; continue; }
    ts=$(( $(ms) - s ))
    [ "$(needs "$W/$f.lib")" -ge 1 ] || { echo "FAIL runtime-lib: $f does not link libRuntime"; fail=1; }
    [ "$(needs "$W/$f.src")" = 0 ] || { echo "FAIL runtime-lib: $f --no-runtime-lib links libRuntime"; fail=1; }
    a=$(cd /tmp && XC_PAR_THREADS=2 "$W/$f.lib" 2>&1); b=$(XC_PAR_THREADS=2 "$W/$f.src" 2>&1)
    [ "$a" = "$b" ] || { echo "FAIL runtime-lib: $f prints '$a' with libRuntime, '$b' without"; fail=1; }
    if [ "$f" = lifted ] && [ $(( tl * 2 )) -ge "$ts" ]; then
        echo "FAIL runtime-lib: the lifted loop took $tl ms with libRuntime, $ts ms without"; fail=1
    fi
done

# 3. Objects and archives on the link line: an xcc object keeps the image's
# runtime its own; a C one takes the library.
cat > "$W/obj.c" <<'EOF'
int seven(void) { return 7; }
EOF
if command -v clang > /dev/null && clang -c -O2 -o "$W/obj.o" "$W/obj.c" 2>/dev/null; then
    cat > "$W/useobj.xc" <<'EOF'
#import "Foundation.xc"
extern i32 seven(void);
i32 main(void)
    {
    Stdio.printf("%d\n", seven());
    return 0;
    }
EOF
    "$XC" -q -O2 -H . "-Wl,$W/obj.o" -o "$W/useobj" "$W/useobj.xc" || { echo "FAIL runtime-lib: the C object link"; fail=1; }
    [ -x "$W/useobj" ] && [ "$(needs "$W/useobj")" -ge 1 ] || { echo "FAIL runtime-lib: a C object link did not take libRuntime"; fail=1; }
    [ -x "$W/useobj" ] && [ "$("$W/useobj")" = 7 ] || { echo "FAIL runtime-lib: the C object link printed '$("$W/useobj" 2>&1)'"; fail=1; }
    cat > "$W/xseven.xc" <<'EOF'
#import "Foundation.xc"
i32 seven(void)
    {
    String* s = String.withCString("seven");
    return (i32)s.byteLength() + (i32)2;
    }
EOF
    if "$XC" -q -O2 -H . -c -o "$W/xseven.o" "$W/xseven.xc"; then
        "$XC" -q -O2 -H . "-Wl,$W/xseven.o" -o "$W/usexobj" "$W/useobj.xc" || { echo "FAIL runtime-lib: the xcc object link"; fail=1; }
        [ -x "$W/usexobj" ] && [ "$(needs "$W/usexobj")" = 0 ] || { echo "FAIL runtime-lib: an xcc object link took libRuntime"; fail=1; }
    else
        echo "FAIL runtime-lib: xcc -c"; fail=1
    fi
fi

# A library linked with a C archive and a par block of its own: it takes the
# library and carries no par runtime, its client's par blocks bind to
# libRuntime, and the client sizes an array the way a program on its own does.
if [ "$PLAT" = osx ] && command -v clang > /dev/null && clang -c -O2 -o "$W/shim.o" "$W/obj.c" 2>/dev/null \
   && ar rcs "$W/libshim.a" "$W/shim.o"; then
    cat > "$W/ShimLib.xc" <<'EOF'
#import "Foundation.xc"
#import "Par.xc"
extern i32 seven(void);
class ShimLib : Object
    {
    static i32 lucky(void) { return seven(); }
    static float total(float* xs, u32 n)
        {
        float s = 0.0;
        par libsum :device(cpu) :reduce(+ s)
            {
            for (u32 i in 0..n)
                s = s + xs[i];
            }
        return s;
        }
    }
EOF
    cat > "$W/shimclient.xc" <<'EOF'
#use <ShimLib>
#import "Stdio.xc"
#import "Par.xc"
#define N 1000000
i32 main(void)
    {
    simd: float* a = new float[N];
    for (u32 i in 0..N)
        a[i] = 1.0;
    Stdio.printf("%d %.1f %ld\n", ShimLib.lucky(), (double)ShimLib.total(a, (u32)1000),
                 Par.spanOf((pointer)((u64)a + (u64)4096), (i64)4, true));
    return 0;
    }
EOF
    mkdir -p "$W/shim"
    if "$XC" -q -O2 -H . --emit-lib "-Wl,$W/libshim.a" -o "$W/shim/libShimLib.dylib" "$W/ShimLib.xc" \
       && "$XC" -q -O2 -H . -L "$W/shim" -o "$W/shim/shimclient" "$W/shimclient.xc"; then
        [ "$(needs "$W/shim/libShimLib.dylib")" -ge 1 ] || { echo "FAIL runtime-lib: a library with a C archive did not take libRuntime"; fail=1; }
        nm -gU "$W/shim/libShimLib.dylib" | grep -q 'Par\$run' && { echo "FAIL runtime-lib: the library exports the par runtime"; fail=1; }
        nm -m "$W/shim/shimclient" | grep 'Par\$run' | grep -q 'from libRuntime' || { echo "FAIL runtime-lib: the client's par blocks do not bind to libRuntime"; fail=1; }
        out=$("$W/shim/shimclient" 2>&1)
        [ "$out" = "7 1000.0 3995904" ] || { echo "FAIL runtime-lib: the library's client printed '$out'"; fail=1; }
    else
        echo "FAIL runtime-lib: the library with a C archive, or its client, does not build"; fail=1
    fi
fi
[ $fail = 0 ] && echo "runtime-lib: ok"
exit $fail
