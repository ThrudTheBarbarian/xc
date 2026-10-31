#!/bin/bash
# compact-object.sh — class instances with the 8-byte header (2026-10-31)
#
# On a compact-objects target (the target row's field: the 64-bit hosts),
# `new C` calls _xtc_alloc_object for an instance with an 8-byte header (magic
# and refcount), every vtable carries the class's dealloc as a fourth header
# word, and weak-list heads of instances live in a side table
# (private:docs/Design/compact-object-header.md). Checked: the row says so,
# `new C` takes the new allocator and `new C[n]` keeps _xtc_alloc, a vtable's
# word 3 is the class's $dealloc (or 0 when it has none), the two compilers
# write the same assembly, and tests/fixtures/compact_object.xc (deallocs,
# subclass chaining, weak zeroing, the side table under 5000 objects, an
# array of class) prints what the 40-byte header printed. With
# XTC_LINUX_ARM64_HOST set it also runs on arm64 Linux.
#
#   [XTC_LINUX_ARM64_HOST=<host>] bash tests/driver/compact-object.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=${REF:-bin/$PLAT/xcc}
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
F=tests/fixtures/compact_object.xc
E=tests/fixtures/compact_object.expected.out
fail=0
for t in arm64 arm64-linux x86_64 win64; do
    "$XC" --print-target -A $t /dev/null 2>/dev/null | grep -qx compact-objects \
        || { echo "FAIL compact-object: the $t row has no compact-objects"; fail=1; }
done
"$XC" --print-target -A wasm32 /dev/null 2>/dev/null | grep -qx compact-objects \
    && { echo "FAIL compact-object: wasm32 says compact-objects"; fail=1; }
"$XC" -q -O0 --emit-ir -o "$W/p0" "$F" 2> "$W/ir" > /dev/null
grep -q 'Call @_xtc_alloc_object, \[' "$W/ir" || { echo "FAIL compact-object: new C does not call _xtc_alloc_object"; fail=1; }
grep -q 'Call @_xtc_alloc, \[' "$W/ir" || { echo "FAIL compact-object: new C[n] no longer calls _xtc_alloc"; fail=1; }
for s in r x; do
    c=$REF; [ $s = x ] && c=$XC
    "$c" -q -O2 -S -o "$W/$s.s" "$F" > "$W/e" 2>&1 || { echo "FAIL compact-object: $(basename "$c") does not compile it"; fail=1; }
done
[ $fail = 0 ] && { cmp -s "$W/r.s" "$W/x.s" || { echo "FAIL compact-object: the two compilers' assembly differs"; fail=1; }; }
word3() { awk -v v="_$1\$vtbl:" '$0 == v {n = 0; next} n >= 0 && /\.quad/ {n++; if (n == 4) {print $2; exit}}' n=-1 "$W/x.s"; }
[ "$(word3 Counted)" = '_Counted$dealloc' ] || { echo "FAIL compact-object: Counted's vtable word 3 is '$(word3 Counted)'"; fail=1; }
[ "$(word3 Plain)" = 0 ] || { echo "FAIL compact-object: Plain's vtable word 3 is '$(word3 Plain)', want 0"; fail=1; }
if [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ]; then
    for o in O0 O2 O3; do
        "$XC" -q -$o -o "$W/p$o" "$F" && "$W/p$o" > "$W/out$o" 2>&1 \
            && cmp -s "$W/out$o" "$E" || { echo "FAIL compact-object: -$o prints: $(head -c 300 "$W/out$o" 2>/dev/null)"; fail=1; }
    done
fi
H=${XTC_LINUX_ARM64_HOST:-}
if [ -n "$H" ]; then
    SSHO="-o BatchMode=yes -o LogLevel=ERROR"
    "$XC" -q -O2 -A arm64-linux -o "$W/pa" "$F" > "$W/e" 2>&1 || { echo "FAIL compact-object: no arm64 Linux build: $(head -c 200 "$W/e")"; exit 1; }
    scp $SSHO -q "$W/pa" "$H:compact-object.bin" && ssh $SSHO "$H" './compact-object.bin; rm -f compact-object.bin' > "$W/outa" 2>&1
    cmp -s "$W/outa" "$E" || { echo "FAIL compact-object: on $H it prints: $(head -c 300 "$W/outa")"; fail=1; }
fi
[ $fail = 0 ] && echo "compact-object: ok"
exit $fail
