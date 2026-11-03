#!/bin/bash
# runtime-lib.sh — libRuntime (2026-11-03): the par runtime and the object
# runtime, prebuilt per target (make runtime-libs), which every program links.
#
#   1. Both compilers build the same libRuntime from Par.xc (--emit-runtime).
#   2. A lifted loop, a written par block and a plain program each link the
#      tree's libRuntime and print what a --no-runtime-lib build of the same
#      source prints; the lifted one compiles in under half the time.
#   3. A link that brings an object (-Wl,x.o) keeps its runtime its own.
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
for f in vec_map_iota par_device_default addr_of_ivar; do
    s=$(ms); "$XC" -q -O2 -H . -o "$W/$f.lib" tests/fixtures/$f.xc || { echo "FAIL runtime-lib: $f does not build"; fail=1; continue; }
    tl=$(( $(ms) - s ))
    s=$(ms); "$XC" -q -O2 -H . --no-runtime-lib -o "$W/$f.src" tests/fixtures/$f.xc || { echo "FAIL runtime-lib: $f --no-runtime-lib"; fail=1; continue; }
    ts=$(( $(ms) - s ))
    [ "$(needs "$W/$f.lib")" -ge 1 ] || { echo "FAIL runtime-lib: $f does not link libRuntime"; fail=1; }
    [ "$(needs "$W/$f.src")" = 0 ] || { echo "FAIL runtime-lib: $f --no-runtime-lib links libRuntime"; fail=1; }
    a=$(cd /tmp && XC_PAR_THREADS=2 "$W/$f.lib" 2>&1); b=$(XC_PAR_THREADS=2 "$W/$f.src" 2>&1)
    [ "$a" = "$b" ] || { echo "FAIL runtime-lib: $f prints '$a' with libRuntime, '$b' without"; fail=1; }
    if [ "$f" = vec_map_iota ] && [ $(( tl * 2 )) -ge "$ts" ]; then
        echo "FAIL runtime-lib: the lifted loop took $tl ms with libRuntime, $ts ms without"; fail=1
    fi
done

# 3. An object on the link line: the image keeps its own runtime.
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
    "$XC" -q -O2 -H . "-Wl,$W/obj.o" -o "$W/useobj" "$W/useobj.xc" || { echo "FAIL runtime-lib: the object link"; fail=1; }
    [ -x "$W/useobj" ] && [ "$(needs "$W/useobj")" = 0 ] || { echo "FAIL runtime-lib: an object link took libRuntime"; fail=1; }
    [ -x "$W/useobj" ] && [ "$("$W/useobj")" = 7 ] || { echo "FAIL runtime-lib: the object link printed '$("$W/useobj" 2>&1)'"; fail=1; }
fi
[ $fail = 0 ] && echo "runtime-lib: ok"
exit $fail
