#!/bin/bash
# arc-atomic.sh — when reference counts are atomic (the security review,
# 2026-10-21): an object two threads retain and release with plain loads and
# stores can be freed twice. Read off the assembly:
#   - arm64 (LSE atomics): always atomic, threads or not (they cost nothing);
#   - x86-64: atomic when the module spawns a thread, has no main (a library
#     or plugin, whose caller may have threads), or loads a plugin; plain
#     otherwise (a locked add costs arc_alloc 3.2x there);
#   - -fno-thread-safe-arc still turns them off, -fthread-safe-arc on.
#
#   bash tests/driver/arc-atomic.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
cat > "$W/p.xc" <<'XC'
#import "Stdio.xc"
class Box : Object
    {
    u32 v;
    }
i32 main(i32 argc, u8** argv)
    {
    Box* b = new Box();
    Box* c = b;
    b.v = (u32)argc;
    Stdio.printf("%u\n", c.v);
    return 0;
    }
XC
cat > "$W/lib.xc" <<'XC'
class Item : Object
    {
    u32 v;
    }
Item* keep;
void hold(Item* i)
    {
    keep = i;
    }
XC
atomics() { grep -cE 'ldadd|lock[[:space:]]+(add|xadd|sub)' "$1"; }
if [ "$PLAT" = osx ]; then
    "$XC" -q -O2 -H . -S -o "$W/a.s" "$W/p.xc" && n=$(atomics "$W/a.s")
    [ "${n:-0}" -gt 0 ] || { echo "FAIL arc-atomic: arm64 keeps plain reference counts in a program with no threads"; fail=1; }
    "$XC" -q -O2 -fno-thread-safe-arc -H . -S -o "$W/a0.s" "$W/p.xc" && n=$(atomics "$W/a0.s")
    [ "${n:-1}" = 0 ] || { echo "FAIL arc-atomic: -fno-thread-safe-arc left $n atomic counts on arm64"; fail=1; }
fi
"$XC" -q -O2 -A x86_64 -H . -S -o "$W/x.s" "$W/p.xc" && n=$(atomics "$W/x.s")
[ "${n:-1}" = 0 ] || { echo "FAIL arc-atomic: x86-64 made a threadless program's counts atomic ($n)"; fail=1; }
"$XC" -q -O2 -A x86_64 -fthread-safe-arc -H . -S -o "$W/x1.s" "$W/p.xc" && n=$(atomics "$W/x1.s")
[ "${n:-0}" -gt 0 ] || { echo "FAIL arc-atomic: -fthread-safe-arc gave no atomic counts on x86-64"; fail=1; }
"$XC" -q -O2 -A x86_64 -H . -c -S -o "$W/l.s" "$W/lib.xc" && n=$(atomics "$W/l.s")
[ "${n:-0}" -gt 0 ] || { echo "FAIL arc-atomic: an x86-64 library (no main) keeps plain reference counts"; fail=1; }
[ $fail = 0 ] && echo "--- arc-atomic: pass ---" || echo "--- arc-atomic: FAIL ---"
exit $fail
