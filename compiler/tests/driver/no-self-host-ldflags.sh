#!/bin/bash
# no-self-host-ldflags.sh — the clang link of `--no-self-host` takes each
# $XTC_LDFLAGS flag once, and the command line's -Wl, flags (#295)
#
# The driver merges $XTC_LDFLAGS into its link lists. The clang link used to
# read the variable a second time, so `-lz` and `-framework CoreFoundation`
# reached clang twice, and it never passed the -L dirs, run paths or other
# flags of a -Wl, list, so `-Wl,-rpath,<dir>`, `-Wl,-L<dir>` and
# `-Wl,-dead_strip` were dropped. Checked: the clang command line (-V) has each
# flag once and the -Wl, flags, the image records the run path and loads libz
# and CoreFoundation, and it runs. Both compilers build the same program
# through clang and give the same run path. macOS only (clang is the host's).
#
#   bash tests/driver/no-self-host-ldflags.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
[ "$(uname -s)" = Darwin ] || { echo "no-self-host-ldflags: skipped (not macOS)"; exit 0; }
command -v clang > /dev/null || { echo "no-self-host-ldflags: skipped (no clang)"; exit 0; }
REF=${REF:-bin/osx/xcc}
XC=${XC:-bin/osx/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0
cat > "$W/p.xc" <<'XC'
#import "Stdio.xc"
i32 main(void)
    {
    Stdio.printf("ldflags %d\n", (i32)42);
    return (i32)0;
    }
XC
want="ldflags 42"
RP=/opt/xc-rpath-test
mkdir -p "$W/lib" "$W/tmp"
count() { tr ' ' '\n' < "$W/line" | grep -c -x -- "$1"; }
for s in r x; do
    c=$REF; [ $s = x ] && c=$XC
    n=$(basename "$c")
    V=; [ $s = x ] && V=-V
    TMPDIR=$W/tmp XTC_LDFLAGS="-lz -L/usr/lib -framework CoreFoundation" \
        "$c" -q -O2 $V --no-self-host "-Wl,-rpath,$RP" "-Wl,-L$W/lib" -Wl,-dead_strip \
        -o "$W/$s" "$W/p.xc" > "$W/e" 2>&1 \
        || { echo "FAIL no-self-host-ldflags: $n does not link through clang: $(head -c 300 "$W/e")"; fail=1; continue; }
    got=$("$W/$s" 2>&1)
    [ "$got" = "$want" ] || { echo "FAIL no-self-host-ldflags: $n prints '$got' (want '$want')"; fail=1; }
    otool -l "$W/$s" | grep -A2 LC_RPATH | grep -q "path $RP " \
        || { echo "FAIL no-self-host-ldflags: $n records no LC_RPATH $RP"; fail=1; }
    otool -L "$W/$s" | grep -q 'libz\.' || { echo "FAIL no-self-host-ldflags: $n does not load libz"; fail=1; }
    otool -L "$W/$s" | grep -q 'CoreFoundation.framework' \
        || { echo "FAIL no-self-host-ldflags: $n does not load CoreFoundation"; fail=1; }
    [ $s = x ] || continue
    # The clang command line, as -V shows it (each word quoted).
    grep -m1 '^xcc: running:.*clang' "$W/e" | tr -d "'" > "$W/line"
    [ -s "$W/line" ] || { echo "FAIL no-self-host-ldflags: $n -V shows no clang command"; fail=1; continue; }
    for f in -lz -L/usr/lib CoreFoundation "-L$W/lib" -Wl,-dead_strip "-Wl,$RP"; do
        k=$(count "$f")
        [ "$k" = 1 ] || { echo "FAIL no-self-host-ldflags: $n passes '$f' $k times (want 1)"; fail=1; }
    done
    grep -q -- "-Wl,-rpath -Wl,$RP" "$W/line" || { echo "FAIL no-self-host-ldflags: $n passes no -rpath $RP"; fail=1; }
    grep -q 'ignoring' "$W/e" && { echo "FAIL no-self-host-ldflags: $n reports a flag clang took as ignored: $(grep -m1 ignoring "$W/e")"; fail=1; }
done
[ $fail = 0 ] && echo "no-self-host-ldflags: ok"
exit $fail
