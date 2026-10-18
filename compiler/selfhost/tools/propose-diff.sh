#!/bin/bash
# propose-diff.sh — IR Propose against the parser's --par-auto scan.
#
# --par-auto finds its candidate loops in the parser's tokens today. IR
# Propose (cpp-front-end.md, step 1) finds them in the IR instead, so loops
# from C and C++ can be found the same way; it replaces the scan only once
# both choose the same loops on the xc corpus. Per fixture, this compares
# the loops the scan made blocks of and the check KEPT (-Wpar-auto: "became
# a 'par' block") with the loops XC_PAR_PROPOSE=report says it would wrap,
# by source line. Loops the scan wrapped and the check then DEMOTED ("runs
# serially") are counted apart: the IR's check will demote them too once it
# runs there, so the IR wrapping one is not a difference yet.
#
#   bash selfhost/tools/propose-diff.sh [pattern]
#   XC=bin/osx/xcc-xc bash selfhost/tools/propose-diff.sh
#
# Prints each fixture where they differ (P: the scan kept a block the IR
# would not wrap, with the IR's reason; I: the IR would wrap a loop the scan
# did not touch) and the totals.
set -u
cd "$(dirname "$0")/../.." || exit 1
XC=${XC:-bin/osx/xcc-xc}
PATTERN=${1:-}
W=$(mktemp -d "${TMPDIR:-/tmp}/propose.XXXX")
trap 'rm -rf "$W"' EXIT
both=0; ponly=0; ionly=0; files=0; differ=0; demoted=0
for f in tests/fixtures/*.xc; do
    [ -n "$PATTERN" ] && [[ "$f" != *"$PATTERN"* ]] && continue
    grep -q '^//xtc-flags:.*target=xt6502' "$f" && continue
    files=$((files + 1))
    "$XC" -q --par-auto -Wpar-auto -H . -o "$W/p" "$f" > "$W/p.out" 2>&1
    grep -E "became a 'par' block" "$W/p.out" \
        | sed -E 's/^[^:]*:([0-9]+):.*/\1/' | sort -n -u > "$W/p.lines"
    grep -E "runs serially, not as a 'par' block" "$W/p.out" \
        | sed -E 's/^[^:]*:([0-9]+):.*/\1/' | sort -n -u > "$W/d.lines"
    XC_PAR_PROPOSE=report "$XC" -q -H . -o "$W/i" "$f" > "$W/i.out" 2>&1
    grep '^propose: ' "$W/i.out" | grep -F "$(basename "$f"):" > "$W/i.all"
    grep ': wrap$' "$W/i.all" | sed -E 's/.*:([0-9]+): wrap$/\1/' | sort -n -u > "$W/i.lines"
    b=$(comm -12 "$W/p.lines" "$W/i.lines" | wc -l)
    p=$(comm -23 "$W/p.lines" "$W/i.lines" | wc -l)
    comm -13 "$W/p.lines" "$W/i.lines" | comm -23 - "$W/d.lines" > "$W/i.only"
    i=$(wc -l < "$W/i.only")
    dm=$(comm -12 "$W/i.lines" "$W/d.lines" | wc -l)
    both=$((both + b)); ponly=$((ponly + p)); ionly=$((ionly + i)); demoted=$((demoted + dm))
    if [ "$p" -gt 0 ] || [ "$i" -gt 0 ]; then
        differ=$((differ + 1))
        echo "$f:"
        for l in $(comm -23 "$W/p.lines" "$W/i.lines"); do
            why=$(grep -E ":$l: no " "$W/i.all" | sed -E 's/.*: no \((.*)\)$/\1/' | head -1)
            echo "  P $l  (IR: ${why:-no loop reported here})"
        done
        for l in $(cat "$W/i.only"); do echo "  I $l"; done
    fi
done
echo "--- propose-diff: $files files, $both loops agreed, $ponly the scan's only, $ionly the IR's only, $differ files differ; $demoted the IR wraps that the scan's check demoted ---"
