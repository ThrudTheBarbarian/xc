#!/bin/bash
# m68k-stack.sh — the Atari ST's stack reserve (#596). _start keeps 64 KB of
# stack unless -ss / --stack-size sets it (rounded up to a long word), in both
# compilers:
#   * the reserve _start asks for: the default, -ss <n> and --stack-size=<hex>;
#   * a recursion whose frames need more than the old 16 KB, and less than
#     64 KB, runs with the default reserve, at -O0 and -O2, on the 68000
#     simulator;
#   * one four times as deep runs when -ss gives it 256 KB;
#   * neither driver calls -ss inert.
set -u
XC_PLAT=${XC_PLAT:-$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )}
cd "$(dirname "$0")/../.." || exit 1
SIM=bin/$XC_PLAT/xcc-sim-68k
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
deep() {  # <depth> -> a program that recurses that deep, each frame ~100 bytes of locals
cat <<EOF
#import "Stdio.xc"
u32 deep(u32 n)
    {
    u32 buf[24];
    for (u32 i in 0..24)
        buf[i] = n * i + (u32)1;
    if (n == (u32)0)
        return buf[3];
    return deep(n - (u32)1) * (u32)31 + buf[n % (u32)24];
    }
i32 main(void)
    {
    Stdio.printf("%u\n", deep((u32)$1));
    return 0;
    }
EOF
}
deep 200 > "$W/d200.xc"
deep 800 > "$W/d800.xc"
echo 1688139909 > "$W/d200.want"
echo 2403596529 > "$W/d800.want"
fail=0
for c in bin/$XC_PLAT/xcc bin/$XC_PLAT/xcc-xc; do
    [ -x "$c" ] || continue
    n=$(basename "$c")
    # The reserve _start asks GEMDOS to keep, past the basepage's 256 bytes.
    for want in "0x10100:" "0x8100:-ss 32768" "0x7634:-ss 30001" "0x8100:--stack-size=0x8000"; do
        hex=${want%%:*}; flags=${want#*:}
        "$c" -q -A atarist -H . $flags -S -o "$W/s.s" "$W/d200.xc" > "$W/e" 2>&1 || { echo "FAIL $n $flags: no build: $(head -c 300 "$W/e")"; fail=1; continue; }
        lit=$(printf '#$%X,d0' "$hex")
        if grep -qF "add.l	$lit" "$W/s.s"; then echo "PASS $n reserve ${flags:-default}"
        else echo "FAIL $n reserve ${flags:-default}: no 'add.l $lit' in _start"; fail=1; fi
        if grep -q "no effect" "$W/e"; then echo "FAIL $n $flags: called inert: $(head -1 "$W/e")"; fail=1; fi
    done
    [ -x "$SIM" ] || continue
    for o in -O0 -O2; do
        for run in "d200:" "d800:-ss 0x40000"; do
            prog=${run%%:*}; flags=${run#*:}
            "$c" -q $o -A atarist -H . $flags -o "$W/a.prg" "$W/$prog.xc" > "$W/e" 2>&1 || { echo "FAIL $n $o $prog: no build: $(head -c 300 "$W/e")"; fail=1; continue; }
            "$SIM" -d "$W/a.prg" < /dev/null 2>/dev/null | tr -d '\r' > "$W/got"
            if cmp -s "$W/got" "$W/$prog.want"; then echo "PASS $n $o $prog ${flags:-default}"
            else echo "FAIL $n $o $prog ${flags:-default}: got '$(head -c 80 "$W/got")', want '$(cat "$W/$prog.want")'"; fail=1; fi
        done
    done
done
[ -x "$SIM" ] || echo "m68k-stack: no 68000 simulator, the runs were skipped"
exit $fail
