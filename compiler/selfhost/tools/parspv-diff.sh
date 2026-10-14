#!/bin/bash
# parspv-diff.sh — the ported `par` GPU kernels against the original's.
# =====================================================================
#
# A `par` block carries its kernel INSIDE the program: for x86-64 and win64 a
# SPIR-V module (and, on win64, the PTX before it). The module is built by the
# ported printer in selfhost/ir/Lower.xc and by the original's in
# src/xtc/ir/XTIRParSPIRV.m, and the two must be the same module — byte for
# byte — or the two compilers disagree about what runs on a Vulkan GPU.
#
#   bash selfhost/tools/parspv-diff.sh [pattern]
#
# Nothing else compares them. `all-diff`'s `x86`/`x65` rows compare the MACHINE
# code of a fixture for the host CPU, which is identical whether or not the
# embedded kernel differs, and the gate's `par-spirv-val` only asks whether each
# module is VALID SPIR-V — a module the port got wrong validates exactly as
# well. Found while porting the device fold (bug 645): the port's fold entry
# point emitted one extra OpAccessChain a tree level and the modules differed by
# 80 words, with both validating and both computing the right answer.
XC_PLAT=${XC_PLAT:-$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )}
XC_HOST_ARCH=${XC_HOST_ARCH:-$( case "$(uname -m)" in (arm64|aarch64) echo arm64 ;; (*) echo x86_64 ;; esac )}
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"

set -u
cd "$(dirname "$0")/../.." || exit 1
BIN=bin/$XC_PLAT
[ -x "$BIN/xcc-xc" ] || BIN=bin/linux
PATTERN=${1:-}

pass=0; fail=0; skip=0
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

for f in tests/fixtures/par_*.xc; do
    [ -e "$f" ] || continue
    b=$(basename "$f" .xc)
    [ -n "$PATTERN" ] && case "$b" in *$PATTERN*) ;; *) continue ;; esac
    grep -qE 'expect=sema-error|xtc-flags: skip' "$f" && continue
    for A in x86_64 win64; do
        mkdir -p "$W/$b.$A.ref" "$W/$b.$A.port"
        "$BIN/xcc"    -q -A $A -H . -O2 -Wno-par-gpu "$f" -o "$W/$b.$A.ref/prog"  >/dev/null 2>&1 || { skip=$((skip+1)); continue; }
        "$BIN/xcc-xc" -q -A $A -H . -O2 -Wno-par-gpu "$f" -o "$W/$b.$A.port/prog" >/dev/null 2>&1 || { skip=$((skip+1)); continue; }
        nref=$(python3 "$(dirname "$0")/spirv-extract.py" "$W/$b.$A.ref/prog"  "$W/$b.$A.ref"  2>/dev/null)
        nport=$(python3 "$(dirname "$0")/spirv-extract.py" "$W/$b.$A.port/prog" "$W/$b.$A.port" 2>/dev/null)
        if [ "${nref:-0}" -eq 0 ] && [ "${nport:-0}" -eq 0 ]; then
            skip=$((skip+1)); continue     # no GPU kernel in this one
        fi
        if [ "${nref:-0}" != "${nport:-0}" ]; then
            echo "FAIL $b ($A): the reference carries ${nref:-0} kernel(s), the port ${nport:-0}"
            fail=$((fail+1)); continue
        fi
        i=0; bad=0
        while [ "$i" -lt "$nref" ]; do
            if ! cmp -s "$W/$b.$A.ref/$i.spv" "$W/$b.$A.port/$i.spv"; then
                echo "FAIL $b ($A): kernel $i differs ($(wc -c < "$W/$b.$A.ref/$i.spv") against $(wc -c < "$W/$b.$A.port/$i.spv") bytes)"
                bad=1
            fi
            i=$((i+1))
        done
        # The PTX kernels too (win64 carries one before each SPIR-V module): the
        # two printers must agree byte for byte, and a block must not silently
        # lose its PTX — a narrow int<->float conversion once dropped the whole
        # kernel to a SPIR-V-only fallback, costing the CUDA card.
        pref=$(python3 "$(dirname "$0")/ptx-extract.py" "$W/$b.$A.ref/prog"  "$W/$b.$A.ref"  2>/dev/null)
        pport=$(python3 "$(dirname "$0")/ptx-extract.py" "$W/$b.$A.port/prog" "$W/$b.$A.port" 2>/dev/null)
        if [ "${pref:-0}" != "${pport:-0}" ]; then
            echo "FAIL $b ($A): the reference carries ${pref:-0} PTX kernel(s), the port ${pport:-0}"
            bad=1
        fi
        j=0
        while [ "$j" -lt "${pref:-0}" ]; do
            if ! cmp -s "$W/$b.$A.ref/$j.ptx" "$W/$b.$A.port/$j.ptx"; then
                echo "FAIL $b ($A): PTX kernel $j differs ($(wc -c < "$W/$b.$A.ref/$j.ptx") against $(wc -c < "$W/$b.$A.port/$j.ptx") bytes)"
                bad=1
            fi
            j=$((j+1))
        done
        if [ "$bad" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); fi
    done
done

echo "parspv-diff: pass=$pass fail=$fail skipped=$skip"
[ "$fail" -eq 0 ] || exit 1
# NOTHING COMPARED is not a pass; a broken oracle turns the sweep into skips.
if [ "$pass" -eq 0 ]; then
    echo "--- $(basename "$0"): NOTHING WAS COMPARED — this is not a pass"
    exit 1
fi
