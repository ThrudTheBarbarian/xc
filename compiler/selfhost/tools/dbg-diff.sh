#!/bin/bash
# dbg-diff.sh — `-g` through the ported back ends, assemblers and writers.
# =================================================================
#
# `-g` stamps source locations on the IR (` !dbg file:line:col`, `dbgfile`
# lines), the arm64 and x86-64 back ends turn them into `.file`/`.loc`, the
# assemblers record the line table and each frame setup, and the DWARF writer
# gives five debug sections that the Mach-O, ELF (static and glibc-dynamic) and
# PE writers place. None of that runs without -g, so every other differential
# is blind to it: they would stay green with the whole path unported.
#
# Per file, with the REFERENCE front end's -g output as the input to both, at
# each level in DBG_LEVELS (default "0 2"):
#   cg-arm64  xcc-cg-arm64 -O<n> asm      vs xtcga64
#   cg-x86    xcc-cg-x86_64 -O<n> asm     vs xtcgx86
#   cg-win64  xcc-cg-win64 -O<n> asm      vs xtcgx86 --win64
# At -O0 the port back end reads the reference's optimised IR, as arm64-diff
# does; above it the PORT's optimiser (xtopt) runs first, so what each pass
# does with an instruction's location is compared through to the assembly.
#   ld-arm64  xcc-ln-arm64 (crt+rt+prog)  vs xtld64          — Mach-O, __DWARF
#   ld-x86    xcc-ln-x86_64 (static)      vs xtldx86         — ELF, .debug_*
#   ld-dyn    xcc-ln-x86_64 --glibc       vs xtldx86 --glibc — dynamic ELF
#   ld-win    xcc-ln-win64                vs xtldwin         — PE, /N sections
# and, when llvm-dwarfdump is on hand, `--verify` of every port-built image
# that carries DWARF (a failure counts as a fail).
#
# The linker tools are built with -DXCC_VERSION, because the DWARF producer
# string is "xcc <version>" in both compilers.
#
#   bash selfhost/tools/dbg-diff.sh [pattern]

set -u
XC_PLAT=${XC_PLAT:-$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )}
XC_HOST_ARCH=${XC_HOST_ARCH:-$( case "$(uname -m)" in (arm64|aarch64) echo arm64 ;; (*) echo x86_64 ;; esac )}
cd "$(dirname "$0")/../.." || exit 1
BIN=bin/$XC_PLAT
[ -x "$BIN/xcc" ] || BIN=bin/linux
PATTERN=${1:-}
WORK=${TMPDIR:-/tmp}/dbgdiff.$$
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
VERSION=$(tr -d ' \n' < VERSION)
TOOL=${XC_TOOL_XCC:-$BIN/xcc}

echo "building the port's back ends and linkers (xtc → native host binaries)…"
"$TOOL" -O2 -A $XC_HOST_ARCH -H . -o "$WORK/xtcga64" selfhost/tools/xtcga64.xc \
    -I selfhost/ir -I selfhost/opt -I selfhost/codegen > "$WORK/b1.log" 2>&1 &
"$TOOL" -O2 -A $XC_HOST_ARCH -H . -o "$WORK/xtcgx86" selfhost/tools/xtcgx86.xc \
    -I selfhost/ir -I selfhost/opt -I selfhost/codegen > "$WORK/b2.log" 2>&1 &
"$TOOL" -O2 -A $XC_HOST_ARCH -H . -DXCC_VERSION="\"$VERSION\"" -o "$WORK/xtld64" \
    selfhost/tools/xtld64.xc -I selfhost/asm > "$WORK/b3.log" 2>&1 &
"$TOOL" -O2 -A $XC_HOST_ARCH -H . -DXCC_VERSION="\"$VERSION\"" -o "$WORK/xtldx86" \
    selfhost/tools/xtldx86.xc -I selfhost/asm > "$WORK/b4.log" 2>&1 &
"$TOOL" -O2 -A $XC_HOST_ARCH -H . -DXCC_VERSION="\"$VERSION\"" -o "$WORK/xtldwin" \
    selfhost/tools/xtldwin.xc -I selfhost/asm > "$WORK/b5.log" 2>&1 &
"$TOOL" -O2 -A $XC_HOST_ARCH -H . -o "$WORK/xtopt" selfhost/tools/xtopt.xc \
    -I selfhost/ir -I selfhost/opt > "$WORK/b6.log" 2>&1 &
wait
for t in xtcga64 xtcgx86 xtld64 xtldx86 xtldwin xtopt; do
    if [ ! -x "$WORK/$t" ]; then
        echo "--- dbg-diff: BROKEN ($t did not build)"
        grep -ah error "$WORK"/b*.log | head -5
        exit 1
    fi
done

DWARFDUMP=""
for d in /opt/homebrew/opt/llvm/bin/llvm-dwarfdump "$(command -v llvm-dwarfdump 2>/dev/null)"; do
    [ -n "$d" ] && [ -x "$d" ] && { DWARFDUMP=$d; break; }
done
[ -z "$DWARFDUMP" ] && echo "(no llvm-dwarfdump: the --verify step is skipped)"

RUN_INCS=(-I selfhost/lexer -I selfhost/preproc -I selfhost/parser
          -I selfhost/sema -I selfhost/ir -I selfhost/opt -I selfhost/codegen
          -I selfhost/asm)
RTX=(support/x86_64/runtime/crt-linux.s support/x86_64/runtime/sys-linux.s
     support/x86_64/runtime/rtgen-linux.s support/x86_64/runtime/rtfiles-linux.s
     support/x86_64/runtime/libmgen-linux.s selfhost/tools/ldx86-rt-shim.s)
RTG=(support/x86_64/runtime/crt-glibc.s support/x86_64/runtime/rtgen-glibc.s
     support/x86_64/runtime/rtfiles-linux.s support/x86_64/runtime/libmgen-linux.s)
GMAP=support/x86_64/glibc-imports.map
RTW=(support/win64/runtime/crt-win64.s support/win64/runtime/rtgen-win64.s
     support/win64/runtime/rtfiles-win64.s support/win64/runtime/libmgen-win64.s)
WMAP=support/win64/win32-imports.map

LEVELS=${DBG_LEVELS:-0 2}
pass=0; fail=0; oracle=0; unsup=0; verified=0
declare -a FAILED

# One comparison: the two files must be identical. `what` names the stage.
same() {
    local what=$1 f=$2 a=$3 b=$4
    if cmp -s "$a" "$b"; then pass=$((pass+1))
    else
        fail=$((fail+1))
        FAILED+=("$what $f ($(cmp -l "$a" "$b" 2>/dev/null | wc -l | tr -d ' ') bytes)")
    fi
}

# A port-built image with DWARF must satisfy llvm-dwarfdump --verify.
verify() {
    local what=$1 f=$2 img=$3
    [ -z "$DWARFDUMP" ] && return
    if "$DWARFDUMP" --verify "$img" > "$WORK/verify.log" 2>&1; then verified=$((verified+1))
    else
        fail=$((fail+1))
        FAILED+=("$what $f (llvm-dwarfdump --verify: $(grep -m1 -i error "$WORK/verify.log"))")
    fi
}

# SHARD_I/SHARD_N: run only every Nth file, so one harness can be split
# across several parallel slots. all-diff uses it on the long ones; the
# default 0/1 is every file, which is what a direct run gets.
FILES=$(find tests support selfhost -name '*.xc' -not -path 'tests/fuzz/findings/*' | sort | awk -v i="${SHARD_I:-0}" -v n="${SHARD_N:-1}" 'NR % n == i')
for f in $FILES; do
    [ -n "$PATTERN" ] && [[ "$f" != *"$PATTERN"* ]] && continue

    # ── optimiser + back ends ──
    for t in arm64 x86_64 win64; do
        if ! "$BIN/xcc-fe" -g -m $t -H . "${RUN_INCS[@]}" "$f" -o "$WORK/pre.ir" >/dev/null 2>&1 \
           || [ ! -s "$WORK/pre.ir" ]; then
            oracle=$((oracle+1)); continue
        fi
        cg=xtcgx86; flag=""
        [ $t = arm64 ] && cg=xtcga64
        [ $t = win64 ] && flag=--win64
        for L in $LEVELS; do
            if ! "$BIN/xcc-cg-$t" -O$L -q -o "$WORK/ref.s" "$WORK/pre.ir" >/dev/null 2>&1; then
                oracle=$((oracle+1)); continue
            fi
            if [ "$L" = 0 ]; then
                "$BIN/xcc-cg-$t" -O0 --dump-opt-ir -q "$WORK/pre.ir" > "$WORK/in.ir" 2>/dev/null \
                    || { oracle=$((oracle+1)); continue; }
            else
                "$WORK/xtopt" "$WORK/pre.ir" -m $t -O$L -o "$WORK/in.ir" >/dev/null 2>&1
                rc=$?
                if [ $rc -eq 3 ]; then unsup=$((unsup+1)); continue; fi
                if [ $rc -ne 0 ]; then fail=$((fail+1)); FAILED+=("opt-$t-O$L $f (exit $rc)"); continue; fi
            fi
            "$WORK/$cg" $flag "$WORK/in.ir" -o "$WORK/port.s" >/dev/null 2>&1
            rc=$?
            if [ $rc -eq 3 ]; then unsup=$((unsup+1))
            elif [ $rc -ne 0 ]; then fail=$((fail+1)); FAILED+=("cg-$t-O$L $f (exit $rc)")
            else same cg-$t-O$L "$f" "$WORK/ref.s" "$WORK/port.s"; fi
        done
    done

    # ── assemblers + writers ──
    # Mach-O: the program after the runtime, as the driver concatenates them.
    if "$BIN/xcc" -g -A arm64 -H . "${RUN_INCS[@]}" -S -o "$WORK/p.s" "$f" >/dev/null 2>&1 \
       && [ -s "$WORK/p.s" ]; then
        cat support/arm64/runtime/crt-macos.s support/arm64/runtime/rt-macos.s "$WORK/p.s" > "$WORK/m.s"
        if "$BIN/xcc-ln-arm64" "$WORK/m.s" "$WORK/m.ref" >/dev/null 2>&1; then
            if "$WORK/xtld64" "$WORK/m.s" "$WORK/m.port" > "$WORK/m.err" 2>&1; then
                same ld-arm64 "$f" "$WORK/m.ref" "$WORK/m.port"
                verify ld-arm64 "$f" "$WORK/m.port"
            else fail=$((fail+1)); FAILED+=("ld-arm64 $f ($(head -1 "$WORK/m.err"))"); fi
        else oracle=$((oracle+1)); fi
    else oracle=$((oracle+1)); fi

    if "$BIN/xcc" -g -A x86_64 -H . "${RUN_INCS[@]}" -S -o "$WORK/e.s" "$f" >/dev/null 2>&1 \
       && [ -s "$WORK/e.s" ]; then
        # Static: the program FIRST (the freestanding runtime after it).
        if "$BIN/xcc-ln-x86_64" "$WORK/e.s" "${RTX[@]}" -o "$WORK/e.ref" >/dev/null 2>&1; then
            if "$WORK/xtldx86" "$WORK/e.s" "${RTX[@]}" -o "$WORK/e.port" > "$WORK/e.err" 2>&1; then
                same ld-x86 "$f" "$WORK/e.ref" "$WORK/e.port"
                verify ld-x86 "$f" "$WORK/e.port"
            else fail=$((fail+1)); FAILED+=("ld-x86 $f ($(head -1 "$WORK/e.err"))"); fi
        else oracle=$((oracle+1)); fi
        # Dynamic (glibc): the program LAST, as `xcc -dynamic` links it.
        if "$BIN/xcc-ln-x86_64" --glibc -importmap "$GMAP" "${RTG[@]}" "$WORK/e.s" \
               -e _start -o "$WORK/d.ref" >/dev/null 2>&1; then
            if "$WORK/xtldx86" --glibc -importmap "$GMAP" "${RTG[@]}" "$WORK/e.s" \
                   -e _start -o "$WORK/d.port" > "$WORK/d.err" 2>&1; then
                same ld-dyn "$f" "$WORK/d.ref" "$WORK/d.port"
                verify ld-dyn "$f" "$WORK/d.port"
            else fail=$((fail+1)); FAILED+=("ld-dyn $f ($(head -1 "$WORK/d.err"))"); fi
        else oracle=$((oracle+1)); fi
    else oracle=$((oracle+2)); fi

    if "$BIN/xcc" -g -A win64 -H . "${RUN_INCS[@]}" -S -o "$WORK/w.s" "$f" >/dev/null 2>&1 \
       && [ -s "$WORK/w.s" ] \
       && "$BIN/xcc-ln-win64" "$WORK/w.s" "${RTW[@]}" -importmap "$WMAP" -o "$WORK/w.ref" >/dev/null 2>&1; then
        if "$WORK/xtldwin" "$WORK/w.s" "${RTW[@]}" -importmap "$WMAP" -o "$WORK/w.port" > "$WORK/w.err" 2>&1; then
            same ld-win "$f" "$WORK/w.ref" "$WORK/w.port"
            verify ld-win "$f" "$WORK/w.port"
        else fail=$((fail+1)); FAILED+=("ld-win $f ($(head -1 "$WORK/w.err"))"); fi
    else oracle=$((oracle+1)); fi
done

if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "--- differing (first 15):"
    printf '  %s\n' "${FAILED[@]}" | head -15
fi
echo "--- dbg-diff: pass=$pass fail=$fail unsupported=$unsup oracle-failed=$oracle (dwarf-verified=$verified) ---"
[ "$fail" -eq 0 ] || exit 1
if [ "$pass" -eq 0 ]; then
    echo "--- $(basename "$0"): NOTHING WAS COMPARED — this is not a pass"
    exit 1
fi
