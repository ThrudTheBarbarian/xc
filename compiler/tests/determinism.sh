#!/bin/sh
# determinism.sh — the compiler must be a deterministic function of its input.
#
# Compiles each fixture TWICE in separate processes and byte-compares the emitted
# assembly. Separate execs matter: ASLR gives each run a different heap layout, so
# any output ordering that leaks an address (an unordered hash-container walk, a
# pointer-sorted list) shows up as a diff here.
#
# Why this is load-bearing: `private:docs/Design/self-hosting.md` §5 — the 3-stage
# bootstrap's whole value is `stage2 == stage3` byte-for-byte, and that requires
# the compiler be deterministic. A non-determinism found here is cheap; the same
# fault found as an intermittent bootstrap failure is not. The discipline this
# enforces (emit from sorted or insertion-ordered sequences, never raw hash
# order) is also what carries over to the self-hosted compiler, since it lives in
# the emitting code rather than in the container.
#
# Usage:  tests/determinism.sh [-A arch] [-n count]
#   -A    target arch (default arm64); repeatable targets are the point of -S
#   -n    limit fixtures (default: all)
set -e
cd "$(dirname "$0")/.."

ARCH=arm64
LIMIT=0
while [ $# -gt 0 ]; do
    case "$1" in
        -A) ARCH=$2; shift 2 ;;
        -n) LIMIT=$2; shift 2 ;;
        *)  echo "usage: $0 [-A arch] [-n count]" >&2; exit 2 ;;
    esac
done

XTC=./bin/osx/xcc
[ -x "$XTC" ] || XTC=./bin/linux/xcc
[ -x "$XTC" ] || { echo "determinism: no xtc binary built"; exit 1; }

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
same=0; diffn=0; skip=0; n=0
FAILED=""

for f in tests/fixtures/*.xc; do
    b=$(basename "$f" .xc)
    # Fixtures pinned to another target, or expected to fail sema, tell us nothing.
    grep -qE '^//xtc-flags:.*(skip|target=)' "$f" && { skip=$((skip+1)); continue; }
    grep -q 'expect=sema-error' "$f" && { skip=$((skip+1)); continue; }
    [ "$LIMIT" -gt 0 ] && [ "$n" -ge "$LIMIT" ] && break

    if ! "$XTC" -A "$ARCH" -S -q "$f" -o "$W/a.s" 2>/dev/null; then skip=$((skip+1)); continue; fi
    if ! "$XTC" -A "$ARCH" -S -q "$f" -o "$W/b.s" 2>/dev/null; then skip=$((skip+1)); continue; fi
    n=$((n+1))

    if cmp -s "$W/a.s" "$W/b.s"; then
        same=$((same+1))
    else
        diffn=$((diffn+1)); FAILED="$FAILED $b"
        # Keep the first offender's pair for diagnosis.
        [ -f /tmp/determinism-a.s ] || { cp "$W/a.s" /tmp/determinism-a.s; cp "$W/b.s" /tmp/determinism-b.s; }
    fi
    rm -f "$W/a.s" "$W/b.s"
done

echo "determinism ($ARCH): $same identical, $diffn differing, $skip skipped"
if [ "$diffn" -gt 0 ]; then
    echo "NON-DETERMINISTIC:"
    for x in $FAILED; do echo "    $x"; done
    echo "first offender's outputs kept at /tmp/determinism-{a,b}.s"
    exit 1
fi
