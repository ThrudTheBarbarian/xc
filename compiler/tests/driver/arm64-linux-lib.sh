#!/bin/bash
# arm64-linux-lib.sh — an arm64 Linux shared library and a program that
# imports it, in both compilers (2026-10-30)
#
# --emit-lib -A arm64-linux writes lib<X>.so with its soname and interface; a
# client's `#import <X>` (with -L) finds the .so alone (no .dylib is tried) and
# names it DT_NEEDED with a DT_RUNPATH of $ORIGIN then its directory. Both
# compilers must write the same bytes; with XTC_LINUX_ARM64_HOST set the
# program runs there beside the library and must print what it should.
#
#   [XTC_LINUX_ARM64_HOST=<host>] bash tests/driver/arm64-linux-lib.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=${REF:-bin/$PLAT/xcc}
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0
mkdir -p "$W/r" "$W/x"
cat > "$W/Adder.xc" <<'XC'
class Adder { i32 base; void init(i32 b) { base = b; } i32 add(i32 x) { return base + x; } }
XC
cat > "$W/use.xc" <<'XC'
#import "Stdio.xc"
#import <Adder>
i32 main(i32 argc, u8** argv)
{
    Adder* a = new Adder(40);
    Stdio.printf("adder %d\n", a.add(argc + 1));
    return 0;
}
XC
for s in r x; do
    c=$REF; [ $s = x ] && c=$XC
    n=$(basename "$c")
    "$c" -q -A arm64-linux --emit-lib -o "$W/$s/libAdder.so" "$W/Adder.xc" > "$W/$s.e" 2>&1 \
        || { echo "FAIL arm64-linux-lib: $n does not build the library: $(head -c 200 "$W/$s.e")"; fail=1; continue; }
    # A stale .dylib beside it must not be taken: android and arm64 Linux load .so alone.
    printf 'junk' > "$W/$s/libAdder.dylib"
    "$c" -q -A arm64-linux -L "$W/$s" -o "$W/$s/use" "$W/use.xc" > "$W/$s.e" 2>&1 \
        || { echo "FAIL arm64-linux-lib: $n does not build the client: $(head -c 200 "$W/$s.e")"; fail=1; }
done
if [ $fail = 0 ]; then
    cmp -s "$W/r/libAdder.so" "$W/x/libAdder.so" || { echo "FAIL arm64-linux-lib: the two libraries differ"; fail=1; }
    # The client names the library's directory, which differs between the two; compare with it blanked.
    LC_ALL=C perl -pe "s#\Q$W/r\E#DIR#g" "$W/r/use" > "$W/r.use"
    LC_ALL=C perl -pe "s#\Q$W/x\E#DIR#g" "$W/x/use" > "$W/x.use"
    cmp -s "$W/r.use" "$W/x.use" || { echo "FAIL arm64-linux-lib: the two clients differ"; fail=1; }
    strings "$W/x/libAdder.so" | grep -qx 'libAdder.so' || { echo "FAIL arm64-linux-lib: no soname"; fail=1; }
    strings "$W/x/use" | grep -qx 'libAdder.so' || { echo "FAIL arm64-linux-lib: the client does not need libAdder.so"; fail=1; }
    strings "$W/x/use" | grep -qx "\$ORIGIN:$W/x" || { echo "FAIL arm64-linux-lib: no RUNPATH \$ORIGIN:<dir>"; fail=1; }
fi
msg="code"
H=${XTC_LINUX_ARM64_HOST:-}
if [ $fail = 0 ] && [ -n "$H" ]; then
    SSHO="-o BatchMode=yes -o LogLevel=ERROR"
    ssh $SSHO "$H" 'rm -rf a64lib && mkdir a64lib' && scp $SSHO -q "$W/x/use" "$W/x/libAdder.so" "$H:a64lib/" \
        || { echo "FAIL: copy to the host"; exit 1; }
    out=$(ssh $SSHO "$H" 'cd a64lib && ./use a; echo "rc=$?"; cd && rm -rf a64lib')
    [ "$out" = "adder 43
rc=0" ] || { echo "FAIL arm64-linux-lib: on the host it printed: $out"; fail=1; }
    msg="code and run"
fi
[ $fail = 0 ] && echo "arm64-linux-lib: ok ($msg)"
exit $fail
