#!/bin/bash
# ldx86dyn-diff.sh — `xcc -A x86_64 -dynamic` (a dynamically linked glibc
# executable), the xtc driver against the Objective-C one: every fixture linked
# by both, the executables compared byte for byte.
#
#   bash selfhost/tools/ldx86dyn-diff.sh [pattern]
#
# xcc-diff already compares the two drivers' assembly; this covers what comes
# after it under -dynamic: the glibc runtime inputs, the per-class allocator
# stubs, the import map, the DT_NEEDED order and the writer. Both links read the
# same checked-in glibc-imports.map, so no glibc is needed on the machine.
#
# SHARD_I/SHARD_N: every Nth fixture.
set -u
XC_PLAT=${XC_PLAT:-$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )}
cd "$(dirname "$0")/../.." || exit 1
BIN=bin/$XC_PLAT; [ -x "$BIN/xcc" ] || BIN=bin/linux
PATTERN=${1:-}
WORK=${TMPDIR:-/tmp}/ldx86dyn.$$
mkdir -p "$WORK"; trap 'rm -rf "$WORK"' EXIT

INCS=(-I support/generic/lib -I support/x86_64/lib)
SELF=(-I selfhost/lexer -I selfhost/preproc -I selfhost/parser -I selfhost/sema
      -I selfhost/ir -I selfhost/opt -I selfhost/codegen -I selfhost/asm
      -I selfhost/link -I selfhost/driver)
HOSTA=$( case "$(uname -m)" in (arm64|aarch64) echo arm64 ;; (*) echo x86_64 ;; esac )
echo "building xcc.xc (the xtc driver)…"
"${XC_TOOL_XCC:-$BIN/xcc}" -O2 -A $HOSTA -H . -o "$WORK/xccxc" selfhost/tools/xcc.xc \
    -I support/generic/lib -I support/$HOSTA/lib "${SELF[@]}" > "$WORK/build.log" 2>&1
if [ ! -x "$WORK/xccxc" ]; then
    echo "--- ldx86dyn-diff: BROKEN (the driver did not build)"
    sed 's/^/    /' "$WORK/build.log" | head -20
    exit 1
fi

pass=0; fail=0; oracle=0; unsup=0
declare -a FAILED
declare -a UNSUP
FIXTURES=$(ls tests/fixtures/*.xc | sort \
    | awk -v i="${SHARD_I:-0}" -v n="${SHARD_N:-1}" 'NR % n == i')
for f in $FIXTURES; do
    [ -n "$PATTERN" ] && [[ "$f" != *"$PATTERN"* ]] && continue
    b=$(basename "$f" .xc)
    rm -f "$WORK/ref" "$WORK/port"
    if ! "$BIN/xcc" -A x86_64 -dynamic -H . -q -O3 -o "$WORK/ref" "$f" >/dev/null 2>&1 \
            || [ ! -s "$WORK/ref" ]; then
        oracle=$((oracle+1)); continue
    fi
    "$WORK/xccxc" -A x86_64 -dynamic -H . "${INCS[@]}" -O3 -o "$WORK/port" "$f" \
        >"$WORK/port.log" 2>&1
    if [ ! -s "$WORK/port" ]; then
        unsup=$((unsup+1)); UNSUP+=("$b — $(head -1 "$WORK/port.log")")
        continue
    fi
    if cmp -s "$WORK/ref" "$WORK/port"; then
        pass=$((pass+1))
    else
        fail=$((fail+1))
        FAILED+=("$b ($(cmp "$WORK/ref" "$WORK/port" | head -1 | sed 's/.*differ: //'))")
    fi
done

echo "--- ldx86dyn-diff: pass=$pass fail=$fail unsupported=$unsup oracle-failed=$oracle ---"
if [ "$fail" -gt 0 ]; then
    echo "--- differing (first 15):"
    printf '  %s\n' "${FAILED[@]}" | head -15
fi
if [ "$unsup" -gt 0 ]; then
    echo "--- the port REFUSED or failed (the reference linked these):"
    printf '  %s\n' "${UNSUP[@]}" | head -10
fi
# Nothing compared is not a pass (private:docs/bugs/239).
if [ "$pass" -eq 0 ]; then
    echo "--- ldx86dyn-diff: NOTHING WAS COMPARED — this is not a pass"
    exit 1
fi
[ "$fail" -eq 0 ] && [ "$unsup" -eq 0 ]
