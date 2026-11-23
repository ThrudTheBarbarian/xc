#!/bin/bash
# bounds-light-targets.sh — -fbounds-check=light reports an out-of-bounds
# subscript on the targets with no POSIX write() (#621): the 6502, through its
# screen (on the simulator), and wasm32, through the host's console (under
# node). Both compilers. Each leg skips when its runner is missing.
set -u
XC_PLAT=${XC_PLAT:-$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )}
cd "$(dirname "$0")/../.." || exit 1
ROOT=$PWD
SIM=bin/$XC_PLAT/xcc-sim-6502
NODE=${NODE:-node}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cat > "$W/oob.xc" <<'EOF'
#import "Stdio.xc"
u16 idx(void) { return (u16)7; }
i32 main(void)
{
    u8 a[4];
    a[idx()] = (u8)1;
    Stdio.printf("unchecked\n");
    return 0;
}
EOF
printf '=== xcc: out-of-bounds access ===\n  at oob.xc:6:6\n  index 7, but the array holds 4 elements\n  aborting\n' > "$W/want"
fail=0; ran=0
for c in bin/$XC_PLAT/xcc bin/$XC_PLAT/xcc-xc; do
    [ -x "$c" ] || continue
    n=$(basename "$c")
    if [ -x "$SIM" ]; then
        if "$c" -q -O0 -A 6502 -H . -fbounds-check=light -o "$W/oob.xex" "$W/oob.xc" > "$W/e" 2>&1; then
            ( cd "$W" && "$ROOT/$SIM" -m xt -d "$W/oob.xex" < /dev/null 2>/dev/null ) | tr -d '\r' | sed '/^$/d' > "$W/got"
            ran=1
            if cmp -s "$W/got" <(sed '/^$/d' "$W/want"); then echo "PASS $n xt6502: the report reaches the screen"
            else echo "FAIL $n xt6502:"; diff "$W/want" "$W/got" | sed 's/^/    /'; fail=1; fi
        else echo "FAIL $n xt6502: no build: $(head -c 300 "$W/e")"; fail=1; fi
    fi
    if command -v "$NODE" > /dev/null 2>&1; then
        if "$c" -q -O0 -A wasm32 -H . -fbounds-check=light -o "$W/oob" "$W/oob.xc" > "$W/e" 2>&1; then
            "$NODE" "$W/oob.js" > "$W/got" 2>&1; rc=$?
            ran=1
            if [ $rc = 134 ] && cmp -s <(sed '/^$/d' "$W/got") <(sed '/^$/d' "$W/want"); then echo "PASS $n wasm32: the report reaches the console, status 134"
            else echo "FAIL $n wasm32: status $rc:"; diff "$W/want" "$W/got" | sed 's/^/    /'; fail=1; fi
        else echo "FAIL $n wasm32: no build: $(head -c 300 "$W/e")"; fail=1; fi
    fi
done
[ $ran = 1 ] || echo "bounds-light-targets: neither xcc-sim-6502 nor node is here, skipped"
exit $fail
