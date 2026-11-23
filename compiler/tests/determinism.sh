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
# order) lives in the emitting code rather than in the container.
#
# It checks the shipped compiler (bin/<host>/xcc-xc, or XCC=...), optimised, for
# each target asked for. A fixture that does not compile for a target is skipped
# for it; one marked `skip` is skipped everywhere.
#
# Usage:  tests/determinism.sh [-A arch]... [-O level] [-n count]
#   -A    a target (repeatable; default arm64)
#   -O    optimisation level (default 2)
#   -n    limit fixtures per target (default: all)
set -e
cd "$(dirname "$0")/.."

ARCHS=""
OPT=2
LIMIT=0
while [ $# -gt 0 ]; do
    case "$1" in
        -A) ARCHS="$ARCHS $2"; shift 2 ;;
        -O) OPT=$2; shift 2 ;;
        -n) LIMIT=$2; shift 2 ;;
        *)  echo "usage: $0 [-A arch]... [-O level] [-n count]" >&2; exit 2 ;;
    esac
done
[ -n "$ARCHS" ] || ARCHS=arm64

XCC=${XCC:-}
[ -n "$XCC" ] || XCC=./bin/osx/xcc-xc
[ -x "$XCC" ] || XCC=./bin/linux/xcc-xc
[ -x "$XCC" ] || { echo "determinism: no shipped compiler built (bin/<host>/xcc-xc, or set XCC)"; exit 1; }

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
status=0

for ARCH in $ARCHS; do
    same=0; diffn=0; skip=0; n=0
    FAILED=""
    for f in tests/fixtures/*.xc; do
        b=$(basename "$f" .xc)
        grep -qE '^//xtc-flags:[[:space:]]*(.*,[[:space:]]*)?skip' "$f" && { skip=$((skip+1)); continue; }
        [ "$LIMIT" -gt 0 ] && [ "$n" -ge "$LIMIT" ] && break

        if ! "$XCC" -q -O"$OPT" -A "$ARCH" -H . -S -o "$W/a.s" "$f" >/dev/null 2>&1; then skip=$((skip+1)); continue; fi
        if ! "$XCC" -q -O"$OPT" -A "$ARCH" -H . -S -o "$W/b.s" "$f" >/dev/null 2>&1; then skip=$((skip+1)); continue; fi
        n=$((n+1))

        if cmp -s "$W/a.s" "$W/b.s"; then
            same=$((same+1))
        else
            diffn=$((diffn+1)); FAILED="$FAILED $b"
            # Keep the first offender's pair per target for diagnosis.
            [ -f "/tmp/determinism-$ARCH-a.s" ] || { cp "$W/a.s" "/tmp/determinism-$ARCH-a.s"; cp "$W/b.s" "/tmp/determinism-$ARCH-b.s"; }
        fi
        rm -f "$W/a.s" "$W/b.s"
    done

    echo "determinism ($ARCH, -O$OPT): $same identical, $diffn differing, $skip skipped"
    if [ "$diffn" -gt 0 ]; then
        echo "NON-DETERMINISTIC ($ARCH):"
        for x in $FAILED; do echo "    $x"; done
        echo "first offender's outputs kept at /tmp/determinism-$ARCH-{a,b}.s"
        status=1
    fi
done
exit $status
