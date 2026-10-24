#!/bin/bash
# wakehook.sh — a block made in a library and called by its client (UXKit,
# 2026-10-24): the library sets RunLoop.main()'s wake hook, the client's
# post() calls it. A block is called through its per-signature base class's
# `invoke` slot, which each module numbered itself; the interface did not
# publish it, so the client called whatever the library kept at its own
# number and every post crashed once the hook was set. Each compiler's
# library with each compiler's client (arm64 here).
#
#   bash tests/crossmod/wakehook.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
[ "$(uname -s)" = Darwin ] || { echo "wakehook: arm64 macOS only, skipped"; exit 0; }
fail=0
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
for L in bin/osx/xcc bin/osx/xcc-xc; do
    for C in bin/osx/xcc bin/osx/xcc-xc; do
        d="$W/$(basename $L)-$(basename $C)"; mkdir -p "$d"
        "$L" -q -A arm64 -H . --emit-lib -o "$d/libRLHookLib.dylib" tests/crossmod/rlhooklib.xc > "$d/out" 2>&1 \
            && "$C" -q -A arm64 -H . -L "$d" -o "$d/p" tests/crossmod/rlhookclient.xc >> "$d/out" 2>&1 \
            || { echo "FAIL $L / $C: build"; head -3 "$d/out"; fail=1; continue; }
        got=$(cd "$d" && DYLD_LIBRARY_PATH=. ./p 2>&1)
        [ "$got" = "drained 2, n=11" ] || { echo "FAIL $L / $C: '$got'"; fail=1; }
    done
done
[ $fail = 0 ] && echo "wakehook: ok"
exit $fail
