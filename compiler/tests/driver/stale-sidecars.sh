#!/bin/bash
# stale-sidecars.sh — -c leaves no sidecar from an earlier build (#297)
#
# `-c` writes `.xtc.iface`, `.xtc.needs` and `.xtc.ir` beside the object. The
# interface and the IR were written only when non-empty and the C path wrote
# none, so `xcc -c -o x.o a.xc` then `xcc -c -o x.o b.c` left a's IR beside
# b's object and `xcc -flto x.o` built a's program. No write was checked.
#
# Both compilers: a module without an interface removes the one an earlier
# build left, and a sidecar that cannot be written fails the build. The
# shipped compiler (which takes C files): a C object carries its own needs
# and no interface or IR, so an object link builds the C program and -flto
# refuses it; a C object with a loop made into a block links on its own.
#
#   bash tests/driver/stale-sidecars.sh
#   REF=<xcc>  XC=<xcc-xc>  override the two drivers
set -u
export XC_PAR_REMOTE=none
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=${REF:-$ROOT/bin/$PLAT/xcc}
XC=${XC:-$ROOT/bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'chmod -R u+w "$W" 2>/dev/null; rm -rf "${W:?}"' EXIT
cat > "$W/lib.xc" <<'EOF'
#import "Foundation.xc"
class Counter : Object
    {
    i32 _n;
    i32 next() { _n = _n + 1; return _n; }
    }
EOF
cat > "$W/a.xc" <<'EOF'
#import "Stdio.xc"
i32 main(void)
{
    Stdio.printf("from-a\n");
    return 0;
}
EOF
cat > "$W/b.c" <<'EOF'
#include <stdio.h>
int main(void)
{
    printf("from-b\n");
    return 0;
}
EOF
cat > "$W/m.c" <<'EOF'
#include <stdio.h>
#define N 65536
static unsigned a[N];
int main(void)
{
    for (unsigned i = 0; i < N; i++)
        a[i] = i * 3u;
    printf("from-m %u\n", a[N - 1]);
    return 0;
}
EOF
fail=0
bad() { echo "FAIL stale-sidecars: $*"; fail=1; }
for c in "$REF" "$XC"; do
    n=$(basename "$c")
    D=$W/$n; mkdir -p "$D"
    # An interface, then a module with none: the first one goes.
    "$c" -q -H "$ROOT" -c -o "$D/x.o" "$W/lib.xc" > "$D/e" 2>&1 || bad "$n -c lib.xc: $(head -c 200 "$D/e")"
    [ -s "$D/x.xtc.iface" ] || bad "$n -c lib.xc wrote no interface"
    [ -s "$D/x.xtc.ir" ] || bad "$n -c lib.xc wrote no IR"
    "$c" -q -H "$ROOT" -c -o "$D/x.o" "$W/a.xc" > "$D/e" 2>&1 || bad "$n -c a.xc: $(head -c 200 "$D/e")"
    grep -q Counter "$D/x.xtc.iface" 2> /dev/null && bad "$n -c a.xc kept lib.xc's interface"
    grep -q Counter "$D/x.xtc.ir" 2> /dev/null && bad "$n -c a.xc kept lib.xc's x.xtc.ir"
    # A sidecar that cannot be written fails the build, naming it.
    mkdir -p "$D/y.xtc.ir"
    "$c" -q -H "$ROOT" -c -o "$D/y.o" "$W/a.xc" > /dev/null 2> "$D/e"
    rc=$?
    [ $rc = 1 ] || bad "$n: an unwritable y.xtc.ir exits $rc, not 1"
    grep -qxF "xcc: error: cannot write '$D/y.xtc.ir'" "$D/e" || bad "$n: an unwritable y.xtc.ir says: $(head -c 200 "$D/e")"
done
# The C path: the shipped compiler alone takes C files.
if command -v cc > /dev/null 2>&1; then
    D=$W/c; mkdir -p "$D"
    "$XC" -q -H "$ROOT" -c -o "$D/x.o" "$W/a.xc" > "$D/e" 2>&1 || bad "-c a.xc: $(head -c 200 "$D/e")"
    "$XC" -q -H "$ROOT" -c -o "$D/x.o" "$W/b.c" > "$D/e" 2>&1 || bad "-c b.c: $(head -c 200 "$D/e")"
    [ -e "$D/x.xtc.ir" ] && bad "-c b.c left a.xc's x.xtc.ir"
    [ -e "$D/x.xtc.iface" ] && bad "-c b.c left an x.xtc.iface"
    [ -e "$D/x.xtc.needs" ] || bad "-c b.c wrote no x.xtc.needs"
    "$XC" -q -H "$ROOT" "$D/x.o" -o "$D/plain" > "$D/e" 2>&1 || bad "link of b.c's object: $(head -c 200 "$D/e")"
    [ "$("$D/plain" 2>&1)" = from-b ] || bad "the object link of b.c's object does not run b.c"
    "$XC" -q -H "$ROOT" -flto "$D/x.o" -o "$D/lto" > "$D/e" 2>&1
    rc=$?
    if [ $rc = 0 ]; then
        [ "$("$D/lto" 2>&1)" = from-b ] || bad "-flto of b.c's object built another program"
    else
        grep -q "x.xtc.ir" "$D/e" || bad "-flto of b.c's object fails without naming x.xtc.ir: $(head -c 200 "$D/e")"
    fi
    # A loop made into a block: the object records what its par runtime needs.
    "$XC" -q -H "$ROOT" -c -o "$D/m.o" "$W/m.c" > "$D/e" 2>&1 || bad "-c m.c: $(head -c 200 "$D/e")"
    "$XC" -q -H "$ROOT" "$D/m.o" -o "$D/m" > "$D/e" 2>&1 || bad "link of m.c's object: $(head -c 300 "$D/e")"
    [ "$("$D/m" 2>&1)" = "from-m 196605" ] || bad "m.c's program prints: $("$D/m" 2>&1 | head -c 200)"
fi
[ $fail = 0 ] && echo "stale-sidecars: ok"
exit $fail
