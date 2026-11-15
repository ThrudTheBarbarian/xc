#!/bin/bash
# warn-once.sh — a warning before the parse prints once under --par-style=auto (#294)
#
# When --par-style=auto finds a loop to make a block of in a program that does
# not import the par runtime, the front end imports it and starts again. The
# shipped compiler printed the preprocessor's warnings and the "no debug
# information" warning from both passes, so a #warning appeared twice under the
# default style and once under --par-style=cpu. Both compilers must print each
# once under auto, cpu and threads.
#
#   bash tests/driver/warn-once.sh
#   REF=<xcc>  XC=<xcc-xc>  override the two drivers
set -u
export XC_PAR_REMOTE=none
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=${REF:-$ROOT/bin/$PLAT/xcc}
XC=${XC:-$ROOT/bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
cat > "$W/w.xc" <<'EOF'
#warning printed-once
#define N 4096
u32 a[N];
i32 main(void)
    {
    for (u32 i in 0..N)
        a[i] = i * (u32)3;
    return (i32)(a[7] & (u32)1);
    }
EOF
# A C library built without debug information, imported by a program that
# also has a loop to make a block of. Skipped where there is no C compiler.
DYLIB=""
if [ "$PLAT" = osx ] && command -v cc > /dev/null 2>&1; then
    printf 'int nd_add(int a, int b) { return a + b; }\n' > "$W/nd.c"
    (cd "$W" && cc -g0 -dynamiclib -o libnd.dylib nd.c) && DYLIB=1
    cat > "$W/d.xc" <<'EOF'
#import <nd>
#define N 4096
i32 nd_add(i32 a, i32 b);
u32 a[N];
i32 main(void)
    {
    for (u32 i in 0..N)
        a[i] = i * (u32)3;
    return (i32)nd_add((i32)(a[7] & (u32)1), (i32)1);
    }
EOF
fi
fail=0
for c in "$REF" "$XC"; do
    n=$(basename "$c")
    for style in auto cpu threads; do
        "$c" -q -H "$ROOT" --par-style=$style -o "$W/w.s" "$W/w.xc" > /dev/null 2> "$W/e"
        rc=$?
        [ $rc = 0 ] || { echo "FAIL warn-once: $n --par-style=$style exits $rc: $(head -c 200 "$W/e")"; fail=1; }
        k=$(grep -c 'warning:.*printed-once' "$W/e")
        [ "$k" = 1 ] || { echo "FAIL warn-once: $n --par-style=$style prints the #warning $k times"; fail=1; }
        if [ -n "$DYLIB" ]; then
            "$c" -q -H "$ROOT" -L "$W" --par-style=$style -o "$W/d.s" "$W/d.xc" > /dev/null 2> "$W/e"
            k=$(grep -c 'has no debug information' "$W/e")
            [ "$k" = 1 ] || { echo "FAIL warn-once: $n --par-style=$style prints the debug-information warning $k times: $(head -c 300 "$W/e")"; fail=1; }
        fi
    done
done
[ $fail = 0 ] && echo "warn-once: ok"
exit $fail
