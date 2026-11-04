#!/bin/bash
# bss-memory.sh — a large zero-filled global costs the compiler no memory.
#
# A 64 MB zero-initialised global is a size and an alignment in the assembler,
# the linker and the image writer: it is never held byte by byte. The xc
# compiler builds the program for -A x86_64, -A arm64-linux and -A arm64 in
# under 200 MB of peak memory, and for every target, -A win64 included, in
# less than 64 MB more than the same program with a 64-byte array (a win64
# compile starts near 200 MB before any of it is assembled). Both compilers
# write the same bytes, and the program prints what it should wherever it can
# run (here, on XTC_X86_HOST / XTC_LINUX_ARM64_HOST, under wine).
#
#   [XTC_X86_HOST=<host>] [XTC_LINUX_ARM64_HOST=<host>] bash tests/driver/bss-memory.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$([ "$(uname -s)" = Darwin ] && echo osx || echo linux)
REF=${REF:-bin/$PLAT/xcc}; XC=${XC:-bin/$PLAT/xcc-xc}
LIMIT_MB=200
W=$(mktemp -d /tmp/bss-memory.XXXX)
trap 'rm -rf "$W"' EXIT
fail=0

cat > "$W/big.xc" <<'EOF'
#import "Stdio.xc"
u8 big[67108864];
u32 words[1024];
i32 main(i32 argc, u8** argv)
    {
    big[0] = (u8)argc;
    big[67108863] = (u8)7;
    words[1023] = (u32)40000;
    u32 sum = (u32)0;
    for (u32 i = (u32)0; i < (u32)67108864; i = i + (u32)4096)
        sum = sum + (u32)big[i];
    Stdio.printf("bss %u %u %u\n", sum, (u32)big[67108863], words[1023]);
    return 0;
    }
EOF
sed 's/u8 big\[67108864\]/u8 big[64]/; s/(u32)67108864/(u32)64/; s/big\[67108863\]/big[63]/g' "$W/big.xc" > "$W/small.xc"
want="bss 1 7 40000"

# Peak resident memory of one command, in MB; the command's status is kept.
peak_mb() {
    local out="$1"; shift
    if [ "$(uname -s)" = Darwin ]; then
        /usr/bin/time -l "$@" 2> "$out.time"; local rc=$?
        awk '/maximum resident set size/ { printf "%d\n", $1 / 1048576 }' "$out.time" > "$out.mb"
        return $rc
    fi
    if /usr/bin/time -v true > /dev/null 2>&1; then
        /usr/bin/time -v "$@" 2> "$out.time"; local rc=$?
        awk -F: '/Maximum resident set size/ { printf "%d\n", $2 / 1024 }' "$out.time" > "$out.mb"
        return $rc
    fi
    "$@"; local rc=$?
    : > "$out.mb"
    return $rc
}

SSHO="-o BatchMode=yes -o LogLevel=ERROR"
remote() { # host binary
    scp $SSHO -q "$2" "$1:bss-memory.bin" || { echo "copy to $1 failed"; return; }
    ssh $SSHO "$1" './bss-memory.bin; rm -f bss-memory.bin'
}

ran=""
for a in x86_64 arm64-linux arm64 win64; do
    ext=""; [ "$a" = win64 ] && ext=".exe"
    if ! "$REF" -q -A $a -o "$W/ref-$a$ext" "$W/big.xc" 2> "$W/err"; then
        echo "FAIL $a: the reference does not build it"; head -3 "$W/err"; fail=1; continue
    fi
    if ! peak_mb "$W/m-$a" "$XC" -q -A $a -o "$W/xc-$a$ext" "$W/big.xc" 2> "$W/err"; then
        echo "FAIL $a: the xc compiler does not build it"; head -3 "$W/err"; fail=1; continue
    fi
    mb=$(cat "$W/m-$a.mb")
    peak_mb "$W/s-$a" "$XC" -q -A $a -o "$W/small-$a$ext" "$W/small.xc" 2> /dev/null
    base=$(cat "$W/s-$a.mb")
    if [ -n "$mb" ] && [ $a != win64 ] && [ "$mb" -ge $LIMIT_MB ]; then
        echo "FAIL $a: the xc compiler peaked at $mb MB (limit $LIMIT_MB MB)"; fail=1
    fi
    if [ -n "$mb" ] && [ -n "$base" ] && [ $((mb - base)) -ge 64 ]; then
        echo "FAIL $a: the 64 MB global cost the xc compiler $((mb - base)) MB ($base -> $mb)"; fail=1
    fi
    cmp -s "$W/ref-$a$ext" "$W/xc-$a$ext" || { echo "FAIL $a: the two compilers' programs differ"; fail=1; }
    sz=$(wc -c < "$W/xc-$a$ext" | tr -d " ")
    [ "$sz" -lt 16777216 ] || { echo "FAIL $a: the program stores its zeros ($sz bytes)"; fail=1; }
    got=""
    case $a in
        arm64) [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] && got=$("$W/xc-$a" 2>&1) ;;
        x86_64) [ -n "${XTC_X86_HOST:-}" ] && got=$(remote "$XTC_X86_HOST" "$W/xc-$a") ;;
        arm64-linux) [ -n "${XTC_LINUX_ARM64_HOST:-}" ] && got=$(remote "$XTC_LINUX_ARM64_HOST" "$W/xc-$a") ;;
        win64) command -v wine > /dev/null 2>&1 \
                   && got=$(cd "$W" && WINEDLLOVERRIDES="winedbg.exe=d;${WINEDLLOVERRIDES:-}" WINEDEBUG=-all \
                            wine "./xc-$a$ext" 2> /dev/null | tr -d '\r') ;;
    esac
    if [ -n "$got" ]; then
        [ "$got" = "$want" ] || { echo "FAIL $a: it printed '$got', want '$want'"; fail=1; }
        ran="$ran $a"
    fi
    echo "  $a: ${mb:-?} MB (${base:-?} MB without the global), $sz bytes"
done
[ $fail = 0 ] && echo "bss-memory: ok (ran:${ran:- none})"
exit $fail
