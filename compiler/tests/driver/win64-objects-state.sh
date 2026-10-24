#!/bin/bash
# win64-objects-state.sh — win64 objects share one standard-library state
# (2026-10-24). Each object compiled with -c carries the stdlib; its file-scope
# globals (class statics, init guards) were local on win64, so code inlined in
# one object read state another had never initialised: the split-built
# xcc.exe printed "(null)" for every string, and looped on any `throw`. Two
# units at -O2, one making strings and one measuring them, linked; the program
# runs under wine where there is one.
#
#   bash tests/driver/win64-objects-state.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
export WINEDLLOVERRIDES="winedbg.exe=d;${WINEDLLOVERRIDES:-}"
fail=0
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cat > "$W/a.xc" <<'XC'
#import "Stdio.xc"
void show(String* s);
i32 main(void)
    {
    String* s = String.withCString("hello");
    Stdio.printf("a: %@\n", s);
    show(s);
    show(String.withU32((u32)42));
    return 0;
    }
XC
cat > "$W/b.xc" <<'XC'
#import "Stdio.xc"
void show(String* s) { Stdio.printf("b: %@ (%u)\n", s, s.byteLength()); }
XC
want=$(printf 'a: hello\nb: hello (5)\nb: 42 (2)')
for XC in ${XC:-bin/$PLAT/xcc-xc bin/$PLAT/xcc}; do
    [ -x "$XC" ] || continue
    d="$W/$(basename "$XC")"; mkdir -p "$d"
    X=$(cd "$(dirname "$XC")" && pwd)/$(basename "$XC"); R=$(pwd)
    ( cd "$d" && "$X" -q -O2 -A win64 -H "$R" -c -o a.o ../a.xc && "$X" -q -O2 -A win64 -H "$R" -c -o b.o ../b.xc \
        && "$X" -q -A win64 -H "$R" -o p.exe a.o b.o ) > "$d/out" 2>&1 \
        || { echo "FAIL $XC: the two objects do not link"; head -3 "$d/out"; fail=1; continue; }
    if command -v wine >/dev/null 2>&1; then
        got=$(cd "$d" && WINEDEBUG=-all timeout 60 wine ./p.exe 2>/dev/null | tr -d '\r')
        [ "$got" = "$want" ] || { echo "FAIL $XC: the program gives"; echo "$got"; fail=1; }
    fi
done
[ $fail = 0 ] && echo "win64-objects-state: ok"
exit $fail
