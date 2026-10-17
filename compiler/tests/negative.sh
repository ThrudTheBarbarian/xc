#!/bin/bash
# negative.sh — every fixture under tests/fixtures/negative/ must be REFUSED,
# with the message its `// xtc: error "…"` line names, by the compiler $XC
# names. These fixtures had no harness: the corpus sweep lists the fixtures
# directory alone, so a program the compiler must reject was never shown to
# it, and a crash on one (class A : A, 2026-10-15) went unseen.
#
#   XC=bin/osx/xcc-xc bash tests/negative.sh
set -u
XC=${XC:-bin/osx/xcc-xc}
A=${A:-arm64}
L=$(mktemp -d "${TMPDIR:-/tmp}/negative.XXXX")
pass=0; fail=0
# `// xtc: error "…"`: the build must fail and say so. `// xtc: warn "…"` (one
# or more): the build must succeed and each warning must appear; `// xtc:
# nowarn "…"`: and this text must not.
for f in tests/fixtures/negative/*.xc; do
    b=$(basename "$f" .xc)
    want=$(grep -m1 -oE 'xtc: error "[^"]*"' "$f" | sed -E 's/^xtc: error "//; s/"$//')
    warns=$(grep -oE 'xtc: warn "[^"]*"' "$f" | sed -E 's/^xtc: warn "//; s/"$//')
    nowarns=$(grep -oE 'xtc: nowarn "[^"]*"' "$f" | sed -E 's/^xtc: nowarn "//; s/"$//')
    if [ -z "$want" ] && [ -z "$warns" ]; then echo "FAIL $b: no // xtc: error or warn line"; fail=$((fail + 1)); continue; fi
    "$XC" -q -O2 -A "$A" -H . -o "$L/$b" "$f" > "$L/$b.out" 2>&1
    rc=$?
    if [ $rc -ge 128 ]; then
        echo "FAIL $b: the compiler died (status $rc)"; fail=$((fail + 1)); continue
    fi
    if [ -n "$want" ]; then
        if [ $rc = 0 ]; then echo "FAIL $b: compiled, expected: $want"; fail=$((fail + 1)); continue; fi
        if grep -qF -- "$want" "$L/$b.out"; then
            pass=$((pass + 1))
        else
            echo "FAIL $b: refused with another message; expected: $want"; sed -n 1,3p "$L/$b.out" | cut -c1-160; fail=$((fail + 1))
        fi
        continue
    fi
    if [ $rc != 0 ]; then echo "FAIL $b: did not compile (warnings expected)"; sed -n 1,3p "$L/$b.out" | cut -c1-160; fail=$((fail + 1)); continue; fi
    ok=1
    while IFS= read -r w; do
        [ -z "$w" ] && continue
        grep -qF -- "$w" "$L/$b.out" || { echo "FAIL $b: no warning: $w"; ok=0; }
    done <<< "$warns"
    while IFS= read -r w; do
        [ -z "$w" ] && continue
        grep -qF -- "$w" "$L/$b.out" && { echo "FAIL $b: a warning it must not give: $w"; ok=0; }
    done <<< "$nowarns"
    if [ $ok = 1 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); fi
done
rm -rf "$L"
echo "--- negative: pass=$pass fail=$fail ---"
[ $fail = 0 ]
