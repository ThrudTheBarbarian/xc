#!/bin/bash
# ifacewrite-diff.sh — the two `.xtc.iface` WRITERS against each other.
# =================================================================
#
# `iface-diff` compares interface CONSUMPTION: it hands both front ends the
# same `.xtc.iface` and compares the client IR. Nothing compared PRODUCTION.
# The linker harnesses (ld64/lddylib/ldx86so/ldandroid/ldarm9) hand the
# ORACLE's blob to both linkers, so they do not either — which left the writer
# as the one artifact in the toolchain that no differential looked at.
#
# It had drifted twice (private:docs/bugs/106): the shipped compiler published every C
# function a library imported as its own export, and gave all the overloads of
# a name the same unmangled symbol.
#
# `--emit-iface` on both sides, so this is a FRONT-END comparison — the
# interface is a front-end fact and running two full library builds per file
# would make the harness the slowest stage in all-diff for nothing.
#
# The comparison is SEMANTIC, not byte-for-byte, and deliberately: the
# reference serialises with NSJSONSerialization, whose key order is sorted only
# on Apple platforms (NSJSONWritingSortedKeys is absent in GNUstep 1.31), so
# its own output is not byte-stable across hosts. What must match is the
# CONTENT — the importer reads the object back by key.
#
#   bash selfhost/tools/ifacewrite-diff.sh [pattern]

set -u
cd "$(dirname "$0")/../.." || exit 1
BIN=bin/osx
[ -x "$BIN/xcc" ] || BIN=bin/linux
PATTERN=${1:-}
WORK=${TMPDIR:-/tmp}/ifacewrite.$$
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

command -v python3 >/dev/null || {
    echo "!!! python3 absent — the JSON comparison cannot run, NOTHING was checked"
    exit 1
}
[ -x "$BIN/xcc-xc" ] || {
    echo "!!! $BIN/xcc-xc missing — run 'make production' first. NOTHING was checked"
    exit 1
}

cat > "$WORK/cmp.py" <<'PY'
import json, sys
def norm(o):
    if isinstance(o, dict):  return {k: norm(v) for k, v in sorted(o.items())}
    if isinstance(o, list):  return [norm(v) for v in o]
    return o
def load(p):
    return norm(json.loads(open(p, 'rb').read().rstrip(b'\x00').decode('utf-8')))
a, b = load(sys.argv[1]), load(sys.argv[2])
if a == b:
    sys.exit(0)
for k in sorted(set(a) | set(b)):
    if a.get(k) != b.get(k):
        print("  %s: port=%s ref=%s" % (k, json.dumps(a.get(k))[:110],
                                           json.dumps(b.get(k))[:110]))
sys.exit(1)
PY

INCS=(-I support/generic/lib -I support/arm64/lib
      -I selfhost/lexer -I selfhost/preproc -I selfhost/parser
      -I selfhost/sema -I selfhost/ir -I selfhost/opt -I selfhost/codegen
      -I selfhost/asm -I selfhost/link -I selfhost/driver)

pass=0; fail=0; oracle=0
declare -a FAILED
FILES=$(find tests support selfhost -name '*.xc' -not -path 'tests/fuzz/findings/*' | sort \
        | awk -v i="${SHARD_I:-0}" -v n="${SHARD_N:-1}" 'NR % n == i')
for f in $FILES; do
    [ -n "$PATTERN" ] && [[ "$f" != *"$PATTERN"* ]] && continue
    rm -f "$WORK/r.json" "$WORK/x.json"
    # A file with nothing public to describe is not a failure of either writer:
    # --emit-iface says so and exits non-zero on both sides.
    if ! "$BIN/xcc" -q -A arm64 -H . --emit-iface "${INCS[@]}" "$f" -o "$WORK/r.json" \
         >/dev/null 2>&1 || [ ! -s "$WORK/r.json" ]; then
        oracle=$((oracle+1)); continue
    fi
    if ! "$BIN/xcc-xc" -q -A arm64 -H . --emit-iface "${INCS[@]}" "$f" -o "$WORK/x.json" \
         >"$WORK/x.err" 2>&1 || [ ! -s "$WORK/x.json" ]; then
        fail=$((fail+1)); FAILED+=("$f (shipped compiler: $(head -1 "$WORK/x.err"))"); continue
    fi
    if out=$(python3 "$WORK/cmp.py" "$WORK/x.json" "$WORK/r.json" 2>&1); then
        pass=$((pass+1))
    else
        fail=$((fail+1)); FAILED+=("$f"$'\n'"$out")
    fi
done

if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "--- differing (first 10):"
    printf '  %s\n' "${FAILED[@]}" | head -30
fi
echo "--- ifacewrite-diff: pass=$pass fail=$fail oracle-failed=$oracle ---"
[ "$pass" -gt 0 ] || { echo "!!! nothing was compared"; exit 1; }
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

