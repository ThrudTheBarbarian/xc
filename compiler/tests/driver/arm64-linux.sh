#!/bin/bash
# arm64-linux.sh — the arm64 Linux (glibc) target, in both compilers
# (2026-10-30)
#
# -A arm64-linux is the arm64 back end in AAPCS64 mode, linked in-house to an
# ELF PIE that names glibc's loader (/lib/ld-linux-aarch64.so.1) and libc.so.6.
# An import nothing defines is refused at link time (support/arm64/glibc-imports.map).
# Both compilers must write the same bytes; with XTC_LINUX_ARM64_HOST set the
# program runs there and must print what it should.
#
#   [XTC_LINUX_ARM64_HOST=<host>] bash tests/driver/arm64-linux.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=${REF:-bin/$PLAT/xcc}
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0
cat > "$W/h.xc" <<'XC'
#import "Stdio.xc"
class Box { i32 v; void init(i32 x) { v = x; } i32 twice(void) { return v * 2; } }
i32 main(i32 argc, u8** argv)
{
    Box* b = new Box(21);
    Stdio.printf("arm64-linux %d %d %.2f\n", b.twice(), argc, 1.5 * (double)argc);
    return 0;
}
XC
"$REF" -q -A arm64-linux -o "$W/r" "$W/h.xc" || { echo "FAIL arm64-linux: the reference does not build it"; fail=1; }
"$XC"  -q -A arm64-linux -o "$W/x" "$W/h.xc" || { echo "FAIL arm64-linux: xcc-xc does not build it"; fail=1; }
[ $fail = 0 ] && { cmp -s "$W/r" "$W/x" || { echo "FAIL arm64-linux: the two compilers' programs differ"; fail=1; }; }
[ $fail = 0 ] && { strings "$W/x" | grep -qx '/lib/ld-linux-aarch64.so.1' \
    || { echo "FAIL arm64-linux: no glibc interpreter in the program"; fail=1; }; }
[ $fail = 0 ] && { strings "$W/x" | grep -qx 'libc.so.6' \
    || { echo "FAIL arm64-linux: libc.so.6 is not needed"; fail=1; }; }
# A symbol neither glibc nor a linked library defines is a link error, in
# both, where it used to link and fail at load ("symbol lookup error").
printf 'i32 nowhere_fn(i32 a);\ni32 main(i32 argc, u8** argv) { return nowhere_fn(argc); }\n' > "$W/u.xc"
for c in "$REF" "$XC"; do
    "$c" -q -A arm64-linux -o "$W/u" "$W/u.xc" > "$W/ue" 2>&1 \
        && { echo "FAIL arm64-linux: $(basename "$c") linked an undefined symbol"; fail=1; }
    grep -q "undefined symbols, which no library the program links defines: 'nowhere_fn'" "$W/ue" \
        || { echo "FAIL arm64-linux: $(basename "$c") did not name the undefined symbol: $(head -c 200 "$W/ue")"; fail=1; }
done
msg="code"
H=${XTC_LINUX_ARM64_HOST:-}
if [ $fail = 0 ] && [ -n "$H" ]; then
    SSHO="-o BatchMode=yes -o LogLevel=ERROR"
    scp $SSHO -q "$W/x" "$H:arm64-linux.bin" || { echo "FAIL: copy to the host"; exit 1; }
    out=$(ssh $SSHO "$H" './arm64-linux.bin a b; echo "rc=$?"; rm -f arm64-linux.bin')
    [ "$out" = "arm64-linux 42 3 4.50
rc=0" ] || { echo "FAIL arm64-linux: on the host it printed: $out"; fail=1; }
    msg="code and run"
fi
[ $fail = 0 ] && echo "arm64-linux: ok ($msg)"
exit $fail
