#!/bin/bash
# x86-vtblload-scratch.sh — the address of a method (`&obj.method`, and so
# respondsTo) on x86-64 and win64 (2026-11-15).
#
# r10 and r11 are caller-saved HOME registers on x86-64, but the vtable and
# itable loads behind `&obj.method` used them as scratch without counting as
# a call, so a value homed in one across the load was overwritten. The loads
# use rcx (the itable walk's cursor) and rdx (the result) now, which are
# never homes, as rax is.
#
# Checked, for tests/fixtures/vtblload_live_homes.xc at -O2 on x86-64 and
# win64: no instruction of a vtable or itable load (from its null default to
# the copy of its result) names r10 or r11, at least one such load was
# found, and the two compilers' assembly is the same.
#
#   bash tests/driver/x86-vtblload-scratch.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=${REF:-bin/$PLAT/xcc}
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
F=tests/fixtures/vtblload_live_homes.xc
fail=0
for A in x86_64 win64; do
    "$REF" -q -H . -A $A -O2 -S -o "$W/ref.s" "$F" 2>/dev/null || { echo "FAIL: $REF did not build $F for $A"; fail=1; continue; }
    "$XC" -q -H . -A $A -O2 -S -o "$W/xc.s" "$F" 2>/dev/null || { echo "FAIL: $XC did not build $F for $A"; fail=1; continue; }
    # Each load: from the line before its null test (the default result) to
    # the line after its done label (the copy of the result into rax).
    out=$(awk '{ l[NR] = $0 }
        END {
            for (i = 1; i <= NR; i++) {
                if (match(l[i], /^\tjz\t\.L_(vtl|pld)_[0-9]+$/) && l[i-1] ~ /^\ttest\trax, rax$/) {
                    split(l[i], p, "\t"); lab = p[3] ":"
                    if (seen[lab]++) continue
                    loads++
                    for (j = i - 2; j <= NR; j++) {
                        if (l[j] ~ /(^|[^a-z0-9])r1[01][dwb]?([^a-z0-9]|$)/) bad = bad "\n    " l[j]
                        if (l[j] == lab) { if (l[j+1] ~ /r1[01]/) bad = bad "\n    " l[j+1]; break }
                    }
                }
            }
            printf "%d%s\n", loads, bad
        }' "$W/xc.s")
    loads=${out%%$'\n'*}
    if [ "$loads" -eq 0 ]; then
        echo "FAIL: $A: no vtable or itable load found"; fail=1
    elif [ "$out" != "$loads" ]; then
        echo "FAIL: $A: a vtable or itable load names r10/r11:${out#*$'\n'}" | head -6; fail=1
    else
        echo "ok: $A: $loads loads, none names r10 or r11"
    fi
    cmp -s "$W/ref.s" "$W/xc.s" && echo "ok: $A: the two compilers agree" \
        || { echo "FAIL: $A: the two compilers' assembly differs"; diff "$W/ref.s" "$W/xc.s" | head -6; fail=1; }
done
[ $fail = 0 ] && echo "--- x86-vtblload-scratch: pass ---" || echo "--- x86-vtblload-scratch: FAIL ---"
exit $fail
