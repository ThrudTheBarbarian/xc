#!/bin/bash
# production.sh — build the toolchain with ITSELF, and prove it stops changing.
# =============================================================================
#
# `bin/osx/*` are BOOTSTRAP binaries: the Objective-C tree built them. A
# PRODUCTION binary is one the xc compiler built. This script makes those and
# checks the property that makes them trustworthy:
#
#   stage1 — the xc driver, built by the Objective-C xcc          (bootstrap)
#   stage2 — the xc driver, built by stage1                       (production)
#   stage3 — the xc driver, built by stage2
#
# The gate is **stage2 == stage3, byte for byte**: a compiler built by itself
# produces itself, so the output has stopped depending on which compiler did
# the building. stage1 vs stage2 is reported too — it is the stronger claim,
# and a difference there with stage2 == stage3 holding means the self-hosted
# compiler is self-consistent but disagrees with the original somewhere.
#
# The comparison is on the emitted ASSEMBLY, not the linked executable: a link
# stamps an LC_UUID that differs between two links of identical input, so two
# Mach-O files differ no matter what compiled them. The `.s` is the whole
# compiler's output — front end, optimiser and back end — and it is
# reproducible, so it is the honest artefact. Each stage therefore builds
# twice: an executable to run the next stage with, and the assembly to compare.
#
#   bash selfhost/tools/production.sh            # the driver
#   KEEP=1 bash selfhost/tools/production.sh     # keep the work directory
#
# This supersedes bootstrap.sh, which still names the pre-0.4 `xtc`/`xtfe` and
# bootstraps only the FRONT END with the Objective-C back end — from before the
# rest of the compiler was ported.
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
BOOT=bin/osx
[ -x "$BOOT/xcc" ] || BOOT=bin/linux

# The include set each tool needs. Defined ABOVE the worker block because a
# bash function has to exist before it is called, and `--one` runs first.
tool_incs() {
    case "$1" in
      # Every assembler, linker, object writer and container dumper. They all
      # take the same set, and SEVEN of them were missing from this list — so
      # they printed SKIP and nothing ever proved they build with the xc
      # compiler rather than only with the bootstrap. "No include set known" is
      # a statement about this table, not about the tool.
      xta6502|xtas64|xtas68|xtas9|xtasx86|xta9so|xtld64|xtldwin|xtldx86| \
      xtlnandroid|xtlnwasm|xtdylib|xtx86so|xtobj64|xtobjx86| \
      elfobjdump|coffobjdump)
          echo "-I selfhost/asm";;
      xtcg65)    echo "-I selfhost/ir -I selfhost/opt -I selfhost/codegen -I selfhost/driver";;
      xtcg68|xtcgwasm|xtcgx86)
                 echo "-I selfhost/ir -I selfhost/opt -I selfhost/codegen";;
      xtcg9)     echo "-I selfhost/ir -I selfhost/codegen";;
      xtcga64)   echo "-I selfhost/lexer -I selfhost/preproc -I selfhost/parser -I selfhost/sema -I selfhost/ir -I selfhost/opt -I selfhost/codegen -I selfhost/asm";;
      # The front end pulls in the whole chain. The set here was originally
      # lifted from bootstrap.sh, where `-I selfhost/driver` is glued onto a
      # SRC= variable rather than being the whole list — so it built with one
      # include path and failed on the first #import. Extraction from a stale
      # script is not the same as knowing what a tool needs.
      xtfe)      echo "-I selfhost/lexer -I selfhost/preproc -I selfhost/parser -I selfhost/sema -I selfhost/ir -I selfhost/driver";;
      xtapk)     echo "-I selfhost/link -I selfhost/asm";;
      xtast)     echo "-I selfhost/lexer -I selfhost/preproc -I selfhost/parser";;
      xtir)      echo "-I selfhost/lexer -I selfhost/preproc -I selfhost/parser -I selfhost/sema -I selfhost/ir -I selfhost/driver";;
      xtirp)     echo "-I selfhost/ir";;
      xtlex)     echo "-I selfhost/lexer";;
      xtopt)     echo "-I selfhost/ir -I selfhost/opt";;
      xtpp)      echo "-I selfhost/preproc";;
      xtsema)    echo "-I selfhost/lexer -I selfhost/preproc -I selfhost/parser -I selfhost/sema";;
      *)         echo "";;
    esac
}

# ── worker mode ──────────────────────────────────────────────────────────────
# `--one <tool>` builds ONE tool twice and records the verdict. The tool loop
# below fans these out with xargs -P: 31 tools x 2 builds is 62 compiles, and
# they were run one after another on a 16-core machine, which is most of why
# this took ~44 minutes. Each iteration only ever touched its own files
# ($WORK/boot.$tool.s, $WORK/prod.$tool.s, its own logs), so the only thing
# standing in the way was the shell counters — solved the way xc-sweep.sh
# already solves it here, with a result file per item tallied at the end.
#
# The THREE-STAGE part above stays serial and always will: stage2 is built by
# stage1 and stage3 by stage2, so there is nothing to overlap.
if [ "${1:-}" = --one ]; then
    tool=$2
    src=selfhost/tools/$tool.xc
    incs=$(tool_incs "$tool")
    b="$PWORK/boot.$tool.s"; p="$PWORK/prod.$tool.s"
    if ! "$BOOT/xcc" -O2 -A arm64 -H . -o "$b" "$src" \
            -I support/generic/lib -I support/arm64/lib $incs \
            > "$PWORK/$tool.boot.log" 2>&1; then
        echo "FAIL	$tool (bootstrap build failed)" > "$PWORK/res/$tool"; exit 0
    fi
    if ! "$PWORK/stage2" -O2 -A arm64 -H . -o "$p" "$src" \
            -I support/generic/lib -I support/arm64/lib $incs \
            > "$PWORK/$tool.prod.log" 2>&1; then
        echo "FAIL	$tool (PRODUCTION build failed)" > "$PWORK/res/$tool"; exit 0
    fi
    if cmp -s "$b" "$p"; then
        echo "OK	$tool" > "$PWORK/res/$tool"
    else
        echo "DIFF	$tool ($(diff "$b" "$p" | grep -c '^[<>]') differing lines)" \
            > "$PWORK/res/$tool"
    fi
    exit 0
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/production.XXXXXX")
if [ "${KEEP:-0}" != 1 ]; then trap 'rm -rf "$WORK"' EXIT; fi

SRC=selfhost/tools/xcc.xc
INCS=(-I support/generic/lib -I support/arm64/lib
      -I selfhost/lexer -I selfhost/preproc -I selfhost/parser -I selfhost/sema
      -I selfhost/ir -I selfhost/opt -I selfhost/codegen -I selfhost/asm
      -I selfhost/link -I selfhost/driver)

# Build the driver with $1, leaving $2 (executable) and $2.s (assembly).
# A build that fails is fatal and says which stage: a stage that silently
# produced nothing would make the NEXT stage compare two missing files and
# call them equal.
# Each stage compiles xcc.xc TWICE — an executable to run the next stage with,
# and the assembly to compare — and the two are independent: same compiler, same
# source, same flags, different -o. Neither reads the other's output, so they
# run CONCURRENTLY.
#
# This is where the time actually is. Three stages x two builds is six full
# builds of the largest program in the tree, and they were strictly serial. The
# tool loop below, which was parallelised first on the assumption that it
# dominated, turned out to be worth only ~5 of the 44 minutes (measured:
# 44 -> 39 at 141% CPU). Pairing these halves the part that does dominate.
#
# The stages themselves stay serial and always will: stage2 is built BY stage1
# and stage3 BY stage2.
build_with() {
    local cc=$1 out=$2 label=$3
    "$cc" -O2 -A arm64 -H . -o "$out"   "$SRC" "${INCS[@]}" > "$out.build.log" 2>&1 &
    local pexe=$!
    "$cc" -O2 -A arm64 -H . -o "$out.s" "$SRC" "${INCS[@]}" > "$out.asm.log"   2>&1 &
    local pasm=$!
    local rcexe=0 rcasm=0
    wait $pexe || rcexe=$?
    wait $pasm || rcasm=$?
    if [ $rcexe -ne 0 ]; then
        echo "--- production: $label FAILED to build"; sed 's/^/    /' "$out.build.log" | grep -iE 'error' | head -20; return 1
    fi
    if [ ! -x "$out" ]; then
        echo "--- production: $label produced no executable"; sed 's/^/    /' "$out.build.log" | tail -20; return 1
    fi
    if [ $rcasm -ne 0 ]; then
        echo "--- production: $label FAILED to emit assembly"; grep -iE 'error' "$out.asm.log" | head -20; return 1
    fi
    [ -s "$out.s" ] || { echo "--- production: $label emitted an EMPTY .s"; return 1; }
    # …and that it IS assembly. The xc driver used to ignore the extension and
    # link an executable regardless, so `-o x.s` produced a Mach-O called x.s —
    # and this script happily compared two of them, reporting a line count of
    # 33,176 for a binary. A harness that cannot tell assembly from an
    # executable is not comparing what it says it is.
    if ! head -c 64 "$out.s" | grep -q 'Generated by'; then
        echo "--- production: $label wrote a NON-ASSEMBLY file to $out.s"
        echo "    (the driver ignored the .s extension and linked instead)"
        return 1
    fi
    return 0
}

echo "stage1: the xc driver, built by the bootstrap compiler ($BOOT/xcc)"
build_with "$BOOT/xcc" "$WORK/stage1" stage1 || exit 1
echo "        $(wc -c < "$WORK/stage1") bytes, $(wc -l < "$WORK/stage1.s") lines of asm"

echo "stage2: the xc driver, built by stage1  — THIS IS THE PRODUCTION BINARY"
build_with "$WORK/stage1" "$WORK/stage2" stage2 || exit 1
echo "        $(wc -c < "$WORK/stage2") bytes, $(wc -l < "$WORK/stage2.s") lines of asm"

echo "stage3: the xc driver, built by stage2"
build_with "$WORK/stage2" "$WORK/stage3" stage3 || exit 1
echo "        $(wc -c < "$WORK/stage3") bytes, $(wc -l < "$WORK/stage3.s") lines of asm"

echo
rc=0
if cmp -s "$WORK/stage2.s" "$WORK/stage3.s"; then
    echo "FIXED POINT: stage2 == stage3 (the compiler builds itself unchanged)"
else
    echo "NOT A FIXED POINT: stage2 != stage3"
    echo "  first difference:"
    cmp "$WORK/stage2.s" "$WORK/stage3.s" 2>&1 | sed 's/^/    /' | head -3
    diff <(head -400000 "$WORK/stage2.s") <(head -400000 "$WORK/stage3.s") 2>/dev/null | head -20 | sed 's/^/    /'
    rc=1
fi

if cmp -s "$WORK/stage1.s" "$WORK/stage2.s"; then
    echo "PARITY:      stage1 == stage2 (bootstrap and production agree)"
else
    echo "DIVERGENCE:  stage1 != stage2 — the two compilers emit different code"
    echo "  $(diff <(cat "$WORK/stage1.s") <(cat "$WORK/stage2.s") 2>/dev/null | grep -c '^[<>]') differing lines"
    diff "$WORK/stage1.s" "$WORK/stage2.s" 2>/dev/null | head -20 | sed 's/^/    /'
    rc=1
fi

# ── every OTHER tool, built both ways ────────────────────────────────────
# The driver is one binary out of 26. "Production" means the whole toolchain
# was built by the xc compiler, so each remaining tool is built twice — by the
# bootstrap compiler and by stage2 — and the assembly compared. Same artefact
# rule as above: `.s`, because a link stamps a varying LC_UUID.
#
# The include set per tool is NOT a superset of selfhost/: `selfhost/asm` and
# `selfhost/codegen` both define Arm64.xc, M68k.xc and X86_64.xc, so a tool
# given both picks up whichever the search order reaches first. Each set below
# is the one its own differential uses.
echo
echo "── the rest of the toolchain: bootstrap vs production ──"
TOOLS_OK=0; TOOLS_DIFF=0; TOOLS_FAIL=0
declare -a TOOL_DIFFS
declare -a TOOL_FAILS


mkdir -p "$WORK/res"
TOOL_LIST=""
for src in selfhost/tools/*.xc; do
    tool=$(basename "$src" .xc)
    [ "$tool" = xcc ] && continue                 # done above, in three stages
    if [ -z "$(tool_incs "$tool")" ]; then
        echo "  SKIP  $tool (no include set known — not built, NOT counted as matching)"
        continue
    fi
    TOOL_LIST="$TOOL_LIST$tool\n"
done

# One process per tool, JOBS at a time. Default CORES-2, leaving the machine
# usable; ALLDIFF-style override for a dedicated box.
CORES=$( (sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null) || echo 4 )
JOBS=${PRODUCTION_JOBS:-$(( CORES > 3 ? CORES - 2 : 1 ))}
export PWORK="$WORK" BOOT
printf "%b" "$TOOL_LIST" | grep -v '^$' \
    | xargs -P "$JOBS" -n 1 "$ROOT/selfhost/tools/production.sh" --one

for f in "$WORK"/res/*; do
    [ -e "$f" ] || continue
    verdict=$(cut -f1 "$f"); detail=$(cut -f2- "$f")
    case "$verdict" in
        OK)   TOOLS_OK=$((TOOLS_OK+1));;
        DIFF) TOOLS_DIFF=$((TOOLS_DIFF+1)); TOOL_DIFFS+=("$detail");;
        FAIL) TOOLS_FAIL=$((TOOLS_FAIL+1)); TOOL_FAILS+=("$detail");;
    esac
done

echo "  identical: $TOOLS_OK   differing: $TOOLS_DIFF   failed: $TOOLS_FAIL"
if [ ${#TOOL_DIFFS[@]} -gt 0 ]; then
    echo "  DIFFERING:"; printf '    %s\n' "${TOOL_DIFFS[@]}"; rc=1
fi
if [ ${#TOOL_FAILS[@]} -gt 0 ]; then
    echo "  FAILED:"; printf '    %s\n' "${TOOL_FAILS[@]}"; rc=1
fi

[ "${KEEP:-0}" = 1 ] && echo "kept: $WORK"
exit $rc
