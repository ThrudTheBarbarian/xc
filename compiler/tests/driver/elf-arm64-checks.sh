#!/bin/bash
# elf-arm64-checks.sh — -fbounds-check=light and -fbounds-check on the arm64
# ELF rows (android, arm64 Linux), in both compilers (2026-10-30)
#
# Both modes build there, and the two compilers write the same bytes. The
# light build inlines its loop checks as on macOS (the port used to decide that
# by the name "arm64" and left android and arm64 Linux out, so the two
# compilers' programs differed), and the debug build takes its reporter from
# Checked.xc, as x86-64 does, where both drivers used to refuse it. With
# XTC_LINUX_ARM64_HOST set, both arm64 Linux programs run there and must stop
# at the bad index.
#
#   [XTC_LINUX_ARM64_HOST=<host>] bash tests/driver/elf-arm64-checks.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=${REF:-bin/$PLAT/xcc}
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0
cat > "$W/b.xc" <<'XC'
#import "Stdio.xc"
i32 main(i32 argc, u8** argv)
{
    i32[4] a;
    i32 s = 0;
    for (i32 k = 0; k < 4; k++) { a[k] = k; s = s + a[k]; }
    i32 i = argc + 5;
    a[i] = s;
    Stdio.printf("no check\n");
    return 0;
}
XC
for t in arm64-android arm64-linux; do
    for m in -fbounds-check=light -fbounds-check; do
        for s in r x; do
            c=$REF; [ $s = x ] && c=$XC
            "$c" -q -A $t $m -o "$W/$s$t$m" "$W/b.xc" > "$W/e" 2>&1 \
                || { echo "FAIL elf-arm64-checks: $(basename "$c") -A $t $m: $(head -c 200 "$W/e")"; fail=1; }
        done
        [ -f "$W/r$t$m" ] && [ -f "$W/x$t$m" ] && { cmp -s "$W/r$t$m" "$W/x$t$m" \
            || { echo "FAIL elf-arm64-checks: -A $t $m: the two compilers' programs differ"; fail=1; }; }
    done
done
msg="code"
H=${XTC_LINUX_ARM64_HOST:-}
if [ $fail = 0 ] && [ -n "$H" ]; then
    SSHO="-o BatchMode=yes -o LogLevel=ERROR"
    for m in -fbounds-check=light -fbounds-check; do
        scp $SSHO -q "$W/xarm64-linux$m" "$H:elf-arm64-checks.bin" || { echo "FAIL: copy to the host"; exit 1; }
        out=$(ssh $SSHO "$H" './elf-arm64-checks.bin a 2>&1; echo "rc=$?"; rm -f elf-arm64-checks.bin')
        case "$out" in
            *"out-of-bounds access"*"index 7"*"rc=134") ;;
            *) echo "FAIL elf-arm64-checks: arm64-linux $m on the host printed: $out"; fail=1 ;;
        esac
    done
    msg="code and run"
fi
[ $fail = 0 ] && echo "elf-arm64-checks: ok ($msg)"
exit $fail
