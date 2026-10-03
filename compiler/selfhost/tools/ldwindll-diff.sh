#!/bin/bash
# ldwindll-diff.sh — the ported PE writer's DLL output against XTPEWriter's.
# =================================================================
# The twin of ldwin-diff, for win64 DLLs (`--emit-lib`). Both linkers get the
# same `.s` files, interface and import map, and their DLLs are compared byte
# for byte.
#
# Its own harness for the same reason ldx86so-diff is: a DLL is not a variation
# on an executable. It has an export directory, a `.reloc` section, an
# `xtciface` section and a DllMain entry, and nothing else in the tree emits
# any of them.
#
#   bash selfhost/tools/ldwindll-diff.sh [pattern]

set -u
XC_PLAT=${XC_PLAT:-$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )}
XC_HOST_ARCH=${XC_HOST_ARCH:-$( case "$(uname -m)" in (arm64|aarch64) echo arm64 ;; (*) echo x86_64 ;; esac )}
cd "$(dirname "$0")/../.." || exit 1
BIN=bin/$XC_PLAT
[ -x "$BIN/xcc" ] || BIN=bin/linux
PATTERN=${1:-}
WORK=${TMPDIR:-/tmp}/ldwindll.$$
mkdir -p "$WORK/a" "$WORK/b"
trap 'rm -rf "$WORK"' EXIT

echo "building xtldwin (xtc → native arm64 host binary)…"
"${XC_TOOL_XCC:-$BIN/xcc}" -O2 -A $XC_HOST_ARCH -H . -o "$WORK/xtldwin" selfhost/tools/xtldwin.xc \
    -I selfhost/asm > "$WORK/build.log" 2>&1
if [ ! -x "$WORK/xtldwin" ]; then grep -a error "$WORK/build.log" | head -5; exit 1; fi

# A DLL's runtime: no crt-win64.s (a DLL has no process entry), and
# dllmain-win64.s as the entry the loader calls.
RT=(support/win64/runtime/rtgen-win64.s support/win64/runtime/rtfiles-win64.s
    support/win64/runtime/libmgen-win64.s support/win64/runtime/dllmain-win64.s)
MAP=support/win64/win32-imports.map
RUN_INCS=(-I selfhost/lexer -I selfhost/preproc -I selfhost/parser
          -I selfhost/sema -I selfhost/ir -I selfhost/opt -I selfhost/codegen
          -I selfhost/asm)
# dllmain-win64.s walks the module's constructor table; the drivers add an
# empty one to a module that has none, and so does this.
printf '\t.data\n__xt_ctors_start:\n__xt_ctors_end:\n\t.text\n' > "$WORK/ctors.s"

pass=0; fail=0; oracle=0
declare -a FAILED

FILES=$(find tests support selfhost -name '*.xc' -not -path 'tests/fuzz/findings/*' | sort | awk -v i="${SHARD_I:-0}" -v n="${SHARD_N:-1}" 'NR % n == i')
for f in $FILES; do
    [ -n "$PATTERN" ] && [[ "$f" != *"$PATTERN"* ]] && continue
    # --emit-lib: a library build is what marks the public methods `.globl`,
    # which is the export list.
    if ! "$BIN/xcc-fe" -A win64 -H . "${RUN_INCS[@]}" -q --emit-lib "$f" \
         -o "$WORK/a.ir" >/dev/null 2>&1 || [ ! -s "$WORK/a.ir" ]; then
        oracle=$((oracle+1)); continue
    fi
    if ! "$BIN/xcc-cg-win64" -O0 -q -o "$WORK/a.s" "$WORK/a.ir" >/dev/null 2>&1 \
       || [ ! -s "$WORK/a.s" ]; then
        oracle=$((oracle+1)); continue
    fi
    IFACE="$WORK/a.ir.iface"; [ -f "$IFACE" ] || IFACE=-
    EXTRA=(); grep -q '^__xt_ctors_start:' "$WORK/a.s" || EXTRA=("$WORK/ctors.s")
    rm -f "$WORK/a/libX.dll" "$WORK/b/libX.dll"
    if ! "$BIN/xcc-ln-win64" "${RT[@]}" ${EXTRA[@]+"${EXTRA[@]}"} "$WORK/a.s" -importmap "$MAP" \
         -shared -iface "$IFACE" -e _xt_dll_main -o "$WORK/a/libX.dll" >/dev/null 2>&1; then
        oracle=$((oracle+1)); continue
    fi
    if ! "$WORK/xtldwin" "${RT[@]}" ${EXTRA[@]+"${EXTRA[@]}"} "$WORK/a.s" -importmap "$MAP" \
         -shared -iface "$IFACE" -e _xt_dll_main -o "$WORK/b/libX.dll" >"$WORK/b.err" 2>&1; then
        fail=$((fail+1)); FAILED+=("$f ($(head -1 "$WORK/b.err"))"); continue
    fi
    if cmp -s "$WORK/a/libX.dll" "$WORK/b/libX.dll"; then pass=$((pass+1))
    else
        fail=$((fail+1))
        FAILED+=("$f ($(cmp -l "$WORK/a/libX.dll" "$WORK/b/libX.dll" 2>/dev/null | wc -l | tr -d ' ') bytes)")
    fi
done

if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "--- differing (first 15):"; printf '  %s\n' "${FAILED[@]}" | head -15
fi
echo "--- ldwindll-diff: pass=$pass fail=$fail oracle-failed=$oracle ---"
[ "$fail" -eq 0 ] || exit 1
# NOTHING COMPARED is not a pass (private:docs/bugs/239).
if [ "$pass" -eq 0 ]; then
    echo "--- $(basename "$0"): NOTHING WAS COMPARED — this is not a pass"
    exit 1
fi
