#!/bin/bash
# tests/nibmod/run.sh — uxkit/026's suggested gate: the CROSS-MODULE shape.
#
# A library-defined designable class and an app-defined one, one "nib" wiring
# both, bound generically — no hand-written setOutlet/wireAction anywhere. The
# app imports the framework as a BINARY module, which matters: importing it as
# source gives the app a private second copy of the loader's statics and hides
# whether the library ever registered at all.
#
# T1 (both modules registered) was the guard for bug 066 — the Mach-O writer
# emitted no __mod_init_func at all, so a LIBRARY's load-time constructors never
# ran. Fixed 2026-08-27; all twelve pass, and T1 stays as the regression guard,
# because the failure it catches is SILENT: nothing errors, the constructor just
# does not happen.
set -u
cd "$(dirname "$0")/../.." || exit 1
BIN=bin/osx; [ -x "$BIN/xcc" ] || BIN=bin/linux
WORK=${TMPDIR:-/tmp}/nibmod.$$
mkdir -p "$WORK"; trap 'rm -rf "$WORK"' EXIT
D=tests/nibmod
fail=0

if ! "$BIN/xcc" -H . -q --emit-lib -o "$WORK/libLibPanel.dylib" "$D/LibPanel.xc" \
        -I "$D" >"$WORK/log" 2>&1; then
    echo "  FAIL nibmod: library build"; sed 's/^/    /' "$WORK/log"; exit 1
fi
if ! "$BIN/xcc" -H . -q -o "$WORK/app" "$D/app.xc" -L "$WORK" >"$WORK/log" 2>&1; then
    echo "  FAIL nibmod: app build"; sed 's/^/    /' "$WORK/log"; exit 1
fi

out=$(DYLD_LIBRARY_PATH="$WORK" "$WORK/app" 2>&1)
echo "$out" | sed 's/^/    /'
# All twelve must pass. `Assert.summary` prints "DONE n" whether or not anything
# failed, so the FAIL lines decide, not it.
fails=$(echo "$out" | grep -c 'FAIL T')
if [ "$fails" = 0 ]; then
    echo "  PASS nibmod: all 12"
elif echo "$out" | grep -q 'FAIL T1'; then
    echo "  FAIL nibmod: T1 — bug 066 is back: a library's load-time"
    echo "       constructors are not running (check __mod_init_func exists"
    echo "       in the dylib: otool -l ... | grep sectname)"; fail=1
else
    echo "  FAIL nibmod: unexpected assertion failures ($fails)"; fail=1
fi
exit $fail
