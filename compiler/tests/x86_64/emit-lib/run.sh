#!/bin/bash
# x86-64 --emit-lib end to end: a .so and a DYNAMIC client, both built here,
# both run on Linux.
#
# The .so writer is gated byte-for-byte by ldx86so-diff. This checks what a
# byte comparison cannot — that the library LOADS:
#
#   * the app is dynamic (PT_INTERP + DT_NEEDED), because a static image has
#     no interpreter and the library it named is simply not there;
#   * the app EXPORTS what the library needs. There is one libc in the image
#     and the executable is the provider, so a symbol the library left
#     undefined must be in the app's dynamic table — and must have been pulled
#     from the archive in the first place, which needs the library's needs to
#     be part of the link's need set;
#   * absolute symbols reached through the GOT get slots holding their value;
#   * a weak undefined in a foreign object (weakobj.py writes one) reads 0
#     through a GOT load and through a data word, and both compilers write the
#     same file for that client.
#
# Needs an x86-64 host: XTC_X86_HOST, or XTC_LINUX_HOST. Says so and skips
# when it cannot reach one — a test that quietly passes without running what it
# built is worse than one that admits it.
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
BIN="$ROOT/bin/osx"; [ -d "$BIN" ] || BIN="$ROOT/bin/linux"
HOST=${XTC_X86_HOST:-${XTC_LINUX_HOST:-}}
LIB="$ROOT/tests/x86_64/emit-lib/TheLib.xc"
APP="$ROOT/tests/x86_64/emit-lib/app.xc"
WAPP="$ROOT/tests/x86_64/emit-lib/weakapp.xc"
WANT=$'add=42\ntwice=42'
WWANT=$'twice=42\ngot=0 word=0'
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

fail=0
python3 "$ROOT/tests/x86_64/emit-lib/weakobj.py" weak.o || { echo "FAIL: could not write weak.o" >&2; exit 1; }
for C in xcc xcc-xc; do
    mkdir -p "$C"
    ( cd "$C" && "$BIN/$C" --emit-lib -A x86_64 -H "$ROOT" -q -o libAdder.so "$LIB" ) || {
        echo "FAIL: $C could not build the .so" >&2; fail=1; continue; }
    ( cd "$C" && "$BIN/$C" -A x86_64 -H "$ROOT" -q -L . -o app "$APP" ) || {
        echo "FAIL: $C could not link the client" >&2; fail=1; continue; }
    ( cd "$C" && "$BIN/$C" -A x86_64 -H "$ROOT" -q -L . -Wl,../weak.o -o weakapp "$WAPP" ) || {
        echo "FAIL: $C could not link the weak-undefined client" >&2; fail=1; continue; }
done
# weakapp is a dynamic link in which a weak undefined resolved to absolute 0:
# its GOT slot holds 0 and its data word gets no RELATIVE relocation.
for f in libAdder.so app weakapp; do
    cmp -s "xcc/$f" "xcc-xc/$f" || { echo "FAIL: the two compilers' $f differ" >&2; fail=1; }
done
if ! ssh -o ConnectTimeout=10 "$HOST" true 2>/dev/null; then
    echo "SKIP: no x86-64 host ($HOST) — built and compared but NOT run"; exit $fail
fi
for C in xcc xcc-xc; do
    ssh "$HOST" 'rm -rf /tmp/xc-emitlib && mkdir -p /tmp/xc-emitlib' </dev/null
    scp -q "$C/app" "$C/weakapp" "$C/libAdder.so" "$HOST":/tmp/xc-emitlib/
    OUT="$(ssh "$HOST" 'cd /tmp/xc-emitlib && ./app' </dev/null 2>&1)"
    [ "$OUT" = "$WANT" ] || { echo "FAIL: $C produced:" >&2; echo "$OUT" >&2; fail=1; }
    OUT="$(ssh "$HOST" 'cd /tmp/xc-emitlib && ./weakapp' </dev/null 2>&1)"
    [ "$OUT" = "$WWANT" ] || { echo "FAIL: $C weakapp produced:" >&2; echo "$OUT" >&2; fail=1; }
done
ssh "$HOST" 'rm -rf /tmp/xc-emitlib' </dev/null
[ $fail -eq 0 ] && echo "PASS (built, compared and ran on $HOST)"
exit $fail
