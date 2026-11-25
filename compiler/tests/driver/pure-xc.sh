#!/bin/bash
# pure-xc.sh — which programs the driver marks as all xc (#15): their main
# calls Par.markPure, and their par blocks keep outputs on a GPU between runs
# by default. A program built and linked here from an xc source is marked; so
# is one importing an xc library built of xc alone (its interface says
# `pure`). One linked with a library (-lm), or importing a library that holds
# a C object, is not. Read from the executable's dynamic imports
# (Par$markPure lives in libRuntime). Skipped where the par runtime imports a
# framework (macOS: nothing is marked) or there is no libRuntime.
#
#   bash tests/driver/pure-xc.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
[ "$PLAT" = osx ] && { echo "--- pure-xc: skipped (macOS: the par runtime imports Metal) ---"; exit 0; }
case "$(uname -m)" in
    x86_64) ROW=x86_64-linux ;;
    aarch64) ROW=arm64-linux ;;
    *) echo "--- pure-xc: skipped (host) ---"; exit 0 ;;
esac
[ -f "support/runtime-lib/$ROW/libRuntime.so" ] || { echo "--- pure-xc: skipped (no libRuntime for $ROW) ---"; exit 0; }
H=$PWD
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0
bad() { echo "  FAIL: $*"; fail=1; }
marked() { readelf --use-dynamic -s "$1" 2>/dev/null | grep -c 'markPure'; }
cd "$W" || exit 1
cat > nb.xc <<'EOF'
class NB { static u32 twice(u32 v) { return v * (u32)2; } }
EOF
cat > m.xc <<'EOF'
#import "Par.xc"
#define N 1024
i32 main(void) { u32* a = new u32[N]; par p { for (u32 i in 0..N) a[i] = i * (u32)3; } Stdio.printf("%u\n", a[5]); return 0; }
EOF
cat > mlib.xc <<'EOF'
#import <nb>
#import "Par.xc"
#define N 1024
i32 main(void) { u32* a = new u32[N]; u32 k = NB.twice((u32)3); par p { for (u32 i in 0..N) a[i] = i * k; } Stdio.printf("%u\n", a[5]); return 0; }
EOF
printf 'unsigned cfun(unsigned v) { return v + 1; }\n' > c.c
for C in xcc-xc xcc; do
    X="$H/bin/$PLAT/$C"
    [ -x "$X" ] || continue
    "$X" -q -H "$H" -o p m.xc > b.log 2>&1 || { bad "$C: m.xc does not build"; continue; }
    [ "$(marked p)" -ge 1 ] || bad "$C: a program of xc alone is not marked"
    "$X" -q -H "$H" -lm -o pl m.xc > b.log 2>&1 || { bad "$C: m.xc -lm does not build"; continue; }
    [ "$(marked pl)" = 0 ] || bad "$C: a program linked with -lm is marked"
    "$X" -q -H "$H" --emit-lib nb.xc -o libnb.so > b.log 2>&1 && "$X" -q -H "$H" -L . -o pp mlib.xc >> b.log 2>&1 \
        || { bad "$C: the pure library or its client does not build"; head -3 b.log; continue; }
    [ "$(marked pp)" -ge 1 ] || bad "$C: a program importing a library of xc alone is not marked"
    if cc -c -fPIC -o c.o c.c 2>/dev/null; then
        "$X" -q -H "$H" --emit-lib nb.xc -Wl,c.o -o libnb.so > b.log 2>&1 && "$X" -q -H "$H" -L . -o pc mlib.xc >> b.log 2>&1 \
            || { bad "$C: the library with a C object or its client does not build"; head -3 b.log; continue; }
        [ "$(marked pc)" = 0 ] || bad "$C: a program importing a library that holds a C object is marked"
    fi
done
[ $fail = 0 ] && echo "--- pure-xc: pass ---" || { echo "--- pure-xc: FAIL ---"; exit 1; }
