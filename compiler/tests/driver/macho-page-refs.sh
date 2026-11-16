#!/bin/bash
# macho-page-refs.sh — the Mach-O writer never leaves an address zero (#350).
#   - A direct @PAGE/@PAGEOFF pair to a symbol a library defines (libRuntime's
#     ___xt_stack_guard) was left unpatched, so the adrp read the start of its
#     own code page. Where the address is taken (adrp + add) it now goes
#     through the import's GOT slot; a load straight from it is refused,
#     naming the symbol and the function.
#   - A GOT pair (@GOTPAGE/@GOTPAGEOFF) naming a symbol the image defines was
#     left unpatched the same way; it is relaxed to the symbol, as ld64 does.
# Read from inline asm, which is where such pairs reach the writer as written.
#
#   bash tests/driver/macho-page-refs.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
XC=${XC:-bin/osx/xcc-xc}
[ "$(uname -s)-$(uname -m)" = Darwin-arm64 ] || { echo "macho-page-refs: skipped (macOS arm64 only)"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0
# A GOT pair and a page pair to a symbol the image defines (main): both
# must give main's address.
cat > "$W/own.xc" <<'XC'
#import "Stdio.xc"
i32 main(void)
    {
    u64 viaPage = (u64)0;
    u64 viaGot = (u64)0;
    asm
    {
        adrp x0, _main@PAGE
        add x0, x0, _main@PAGEOFF
        str x0, [viaPage]
        adrp x1, _main@GOTPAGE
        ldr x1, [x1, _main@GOTPAGEOFF]
        str x1, [viaGot]
    }
    Stdio.printf("%s\n", viaPage == viaGot && viaGot != (u64)0 ? "same" : "differ");
    return 0;
    }
XC
"$XC" -q -O2 -H . -o "$W/own" "$W/own.xc" > "$W/e" 2>&1 || { echo "FAIL macho-page-refs: the own-symbol case does not build: $(head -c 300 "$W/e")"; fail=1; }
[ -x "$W/own" ] && { got=$("$W/own"); [ "$got" = same ] || { echo "FAIL macho-page-refs: a GOT pair to a symbol the image defines reads the wrong address"; fail=1; }; }
LIB=support/runtime-lib/arm64-macos/libRuntime.dylib
if [ -f "$LIB" ]; then
    sed 's/_main@/___xt_stack_guard@/g' "$W/own.xc" > "$W/imp.xc"
    "$XC" -q -O2 -H . -o "$W/imp" "$W/imp.xc" > "$W/e" 2>&1 || { echo "FAIL macho-page-refs: the import case does not build: $(head -c 300 "$W/e")"; fail=1; }
    if [ -x "$W/imp" ]; then
        otool -L "$W/imp" | grep -q libRuntime || echo "  note: libRuntime is not linked, so the guard is not an import here"
        got=$("$W/imp"); [ "$got" = same ] || { echo "FAIL macho-page-refs: an @PAGE/add pair to an import does not give its address"; fail=1; }
    fi
    cat > "$W/load.xc" <<'XC'
#import "Stdio.xc"
i32 main(void)
    {
    u64 v = (u64)0;
    asm
    {
        adrp x0, ___xt_stack_guard@PAGE
        ldr x1, [x0, ___xt_stack_guard@PAGEOFF]
        str x1, [v]
    }
    Stdio.printf("%llu\n", v);
    return 0;
    }
XC
    if "$XC" -q -O2 -H . -o "$W/load" "$W/load.xc" > "$W/e" 2>&1; then
        echo "FAIL macho-page-refs: a direct load of an import through @PAGEOFF linked"; fail=1
    elif ! grep -q "'__xt_stack_guard' is loaded or stored directly in 'main'" "$W/e"; then
        echo "FAIL macho-page-refs: the refusal does not name the symbol and function: $(head -c 300 "$W/e")"; fail=1
    fi
else
    echo "  macho-page-refs: import cases skipped (no $LIB: make runtime-libs)"
fi
[ $fail = 0 ] && echo "macho-page-refs: ok"
exit $fail
