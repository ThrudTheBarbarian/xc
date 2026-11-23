#!/bin/bash
# m68k-stack.sh — the Atari ST's stack reserve (#596). _start keeps 64 KB of
# stack unless -ss / --stack-size sets it (rounded up to a long word), in both
# compilers:
#   * the reserve _start asks for: the default, -ss <n> and --stack-size=<hex>;
#   * a recursion whose frames need more than the old 16 KB, and less than
#     64 KB, runs with the default reserve, at -O0 and -O2, on the 68000
#     simulator;
#   * one four times as deep runs when -ss gives it 256 KB;
#   * the guard: with -ss 16384 at -O0, 40 levels run and 60 levels stop with
#     "stack overflow: the 16 KB stack was exceeded" and exit status 1 (60 is
#     past the reserve but not so far that it overwrites the program's code);
#   * -fbounds-check: each prologue checks its frame, so 200 levels in 16 KB
#     stop at once with "stack overflow in deep: …" and status 1 (at -O0 and
#     -O2), 40 levels still run, and without the flag no check is emitted;
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
deep 40 > "$W/d40.xc"
deep 60 > "$W/d60.xc"
deep 200 > "$W/d200.xc"
deep 800 > "$W/d800.xc"
echo 4181725109 > "$W/d40.want"
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
        if grep -q "__xtc_stack_limit\|__xtc_stack_overflow_at" "$W/s.s"; then echo "FAIL $n $flags: a prologue check without -fbounds-check"; fail=1; fi
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
    # -fbounds-check: the prologue check names the function that overflows.
    for o in -O0 -O2; do
        for prog in d40 d200; do
            "$c" -q $o -A atarist -H . -fbounds-check -ss 16384 -o "$W/p.prg" "$W/$prog.xc" > "$W/e" 2>&1 || { echo "FAIL $n $o prologue $prog: no build: $(head -c 300 "$W/e")"; fail=1; continue; }
            "$SIM" -d "$W/p.prg" < /dev/null 2>/dev/null | tr -d '\r' > "$W/got"; rc=${PIPESTATUS[0]}
            if [ $prog = d40 ]; then
                if [ $rc = 0 ] && cmp -s "$W/got" "$W/d40.want"; then echo "PASS $n $o -fbounds-check: 40 levels fit 16 KB"
                else echo "FAIL $n $o -fbounds-check: 40 levels in 16 KB: status $rc, '$(head -c 80 "$W/got")'"; fail=1; fi
            elif [ $rc = 1 ] && [ "$(cat "$W/got")" = "stack overflow in deep: the 16 KB stack was exceeded; raise it with -ss" ]; then
                echo "PASS $n $o -fbounds-check: 200 levels stop in deep"
            else echo "FAIL $n $o -fbounds-check: 200 levels in 16 KB: status $rc, '$(tail -c 160 "$W/got")'"; fail=1; fi
        done
    done
    # -fbounds-check checks subscripts on the ST too, reporting on the console.
    printf '#import "Stdio.xc"\nu32 idx(void) { return (u32)7; }\ni32 main(void)\n{\n    u8 a[4];\n    a[idx()] = (u8)1;\n    Stdio.printf("unchecked\\n");\n    return 0;\n}\n' > "$W/oob.xc"
    for fl in -fbounds-check -fbounds-check=light; do
        "$c" -q -O0 -A atarist -H . $fl -o "$W/o.prg" "$W/oob.xc" > "$W/e" 2>&1 || { echo "FAIL $n $fl subscript: no build: $(head -c 300 "$W/e")"; fail=1; continue; }
        "$SIM" -d "$W/o.prg" < /dev/null 2>/dev/null | tr -d '\r' > "$W/got"; rc=${PIPESTATUS[0]}
        if [ $rc = 134 ] && grep -q "index 7, but the array holds 4 elements" "$W/got"; then echo "PASS $n $fl: an out-of-bounds subscript stops the ST program"
        else echo "FAIL $n $fl subscript: status $rc, '$(head -c 160 "$W/got" | tr '\n' '|')'"; fail=1; fi
    done
    # The guard: the stack check stops an overflow, and leaves a fit alone.
    for prog in d40 d60; do
        "$c" -q -O0 -A atarist -H . -ss 16384 -o "$W/g.prg" "$W/$prog.xc" > "$W/e" 2>&1 || { echo "FAIL $n guard $prog: no build: $(head -c 300 "$W/e")"; fail=1; continue; }
        "$SIM" -d "$W/g.prg" < /dev/null 2>/dev/null | tr -d '\r' > "$W/got"; rc=${PIPESTATUS[0]}
        if [ $prog = d40 ]; then
            if [ $rc = 0 ] && cmp -s "$W/got" "$W/d40.want"; then echo "PASS $n guard: 40 levels fit 16 KB"
            else echo "FAIL $n guard: 40 levels in 16 KB: status $rc, '$(head -c 80 "$W/got")'"; fail=1; fi
        elif [ $rc = 1 ] && grep -q "^stack overflow: the 16 KB stack was exceeded; raise it with -ss$" "$W/got"; then
            echo "PASS $n guard: 60 levels stop with stack overflow"
        else echo "FAIL $n guard: 60 levels in 16 KB: status $rc, '$(tail -c 120 "$W/got")'"; fail=1; fi
    done
done
[ -x "$SIM" ] || echo "m68k-stack: no 68000 simulator, the runs were skipped"
exit $fail
