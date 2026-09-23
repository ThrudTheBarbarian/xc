#!/bin/bash
# lddylib-diff.sh — the ported Mach-O DYLIB writer against XTMachOWriter.
# =================================================================
# The twin of ld64-diff, for shared libraries. Both writers get the SAME `.s`,
# the same install name, the same interface blob and the same export list, and
# their OUTPUT FILES are compared byte for byte.
#
# Worth its own harness rather than a case in ld64-diff, because a dylib is not
# a variation on an executable: base 0 with no __PAGEZERO (so the bind and
# rebase opcodes name a different segment), MH_DYLIB with LC_ID_DYLIB instead
# of LC_MAIN, FLAT binds, an __XTC,__iface section, and — the part nothing else
# in the tree exercises — the dyld EXPORT TRIE. A name missing from that trie
# does not exist as far as the loader is concerned however many nlist entries
# mention it, and the failure lands in the CLIENT.
#
#   bash selfhost/tools/lddylib-diff.sh [pattern]

set -u
cd "$(dirname "$0")/../.." || exit 1
BIN=bin/osx
[ -x "$BIN/xcc" ] || BIN=bin/linux
PATTERN=${1:-}
WORK=${TMPDIR:-/tmp}/lddylibdiff.$$
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

echo "building xtdylib (xtc → native arm64 host binary)…"
"$BIN/xcc" -O2 -A arm64 -H . -o "$WORK/xtdylib" selfhost/tools/xtdylib.xc \
    -I selfhost/asm > "$WORK/build.log" 2>&1
if [ ! -x "$WORK/xtdylib" ]; then
    grep -a error "$WORK/build.log" | head -5
    exit 1
fi

RUN_INCS=(-I selfhost/lexer -I selfhost/preproc -I selfhost/parser
          -I selfhost/sema -I selfhost/ir -I selfhost/opt -I selfhost/codegen
          -I selfhost/asm)

pass=0; fail=0; oracle=0
declare -a FAILED

FILES=$(find tests support selfhost -name '*.xc' -not -path 'tests/fuzz/findings/*' | sort | awk -v i="${SHARD_I:-0}" -v n="${SHARD_N:-1}" 'NR % n == i')
for f in $FILES; do
    [ -n "$PATTERN" ] && [[ "$f" != *"$PATTERN"* ]] && continue
    # --emit-lib, because a LIBRARY build is what this writer is for: every
    # instance method earns a vtable slot, and the interface is produced.
    if ! "$BIN/xcc-fe" -A arm64 -H . "${RUN_INCS[@]}" -q --emit-lib "$f" \
         -o "$WORK/a.ir" >/dev/null 2>&1 || [ ! -s "$WORK/a.ir" ]; then
        oracle=$((oracle+1)); continue
    fi
    if ! "$BIN/xcc-cg-arm64" -O0 -q -o "$WORK/a.s" "$WORK/a.ir" >/dev/null 2>&1 \
       || [ ! -s "$WORK/a.s" ]; then
        oracle=$((oracle+1)); continue
    fi
    # Every defined label is a candidate export — the widest surface, which is
    # what stresses the trie hardest. The writers agree on which of them are
    # actually defined, so both drop the same ones.
    grep -o '^_[A-Za-z0-9_$]*:' "$WORK/a.s" | tr -d ':' | sort -u > "$WORK/exp.txt"
    IFACE="$WORK/a.ir.iface"; [ -f "$IFACE" ] || IFACE=-
    if ! "$BIN/xcc-ln-arm64" --dylib libX.dylib "$IFACE" "$WORK/exp.txt" \
         "$WORK/a.s" "$WORK/a.dylib" >/dev/null 2>&1; then
        oracle=$((oracle+1)); continue
    fi
    if ! "$WORK/xtdylib" libX.dylib "$IFACE" "$WORK/exp.txt" \
         "$WORK/a.s" "$WORK/b.dylib" >"$WORK/b.err" 2>&1; then
        fail=$((fail+1)); FAILED+=("$f ($(head -1 "$WORK/b.err"))"); continue
    fi
    if cmp -s "$WORK/a.dylib" "$WORK/b.dylib"; then
        pass=$((pass+1))
    else
        fail=$((fail+1))
        FAILED+=("$f ($(cmp -l "$WORK/a.dylib" "$WORK/b.dylib" 2>/dev/null | wc -l | tr -d ' ') bytes)")
    fi
done

if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "--- differing (first 15):"
    printf '  %s\n' "${FAILED[@]}" | head -15
fi
echo "--- lddylib-diff: pass=$pass fail=$fail oracle-failed=$oracle ---"
[ "$fail" -eq 0 ] || exit 1
# NOTHING COMPARED is not a pass. Every one of these harnesses counts an oracle
# failure — a file the REFERENCE could not build — and skips it, so a broken
# oracle turns the whole sweep into skips and the summary reads pass=0 fail=0.
# Only `fail` was ever checked, so that exited 0 and showed as a clean row in
# all-diff's table. It has now happened twice on ldx86-diff alone, the second
# time hiding 961 uncompared files. private:docs/bugs/239.
if [ "$pass" -eq 0 ]; then
    echo "--- $(basename "$0"): NOTHING WAS COMPARED — this is not a pass"
    exit 1
fi

