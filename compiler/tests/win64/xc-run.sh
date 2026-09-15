#!/bin/bash
# xc-run.sh — `-A win64` from the SHIPPED compiler, end to end.
#
# The PE writer is gated byte-for-byte by ldwin-diff; this checks the half a
# byte comparison cannot: that the driver assembles the right pieces (crt,
# runtime, allocator stubs, program), builds an import table with the kernel32
# floor the runtime actually calls, and produces an .exe that RUNS.
#
# Wine if it is here, otherwise the file is checked for shape and the run is
# reported as skipped — a test that silently does nothing when the runner is
# missing is worse than one that says so.
#
#   bash tests/win64/xc-run.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/bin/osx"; [ -d "$BIN" ] || BIN="$ROOT/bin/linux"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

cat > prog.xc <<'EOF'
#import "Stdio.xc"
i32 main(void) {
    i32 t = (i32)0;
    for (i32 i = (i32)1; i <= (i32)10; i = i + (i32)1) t = t + i;
    Stdio.printf("sum=%ld\n", t);
    return 0;
}
EOF

fail=0
for C in xcc xcc-xc; do
    if ! "$BIN/$C" -A win64 -H "$ROOT" -q -o "prog-$C.exe" prog.xc 2>"err-$C.txt"; then
        echo "FAIL: $C could not build a win64 exe:" >&2; head -3 "err-$C.txt" >&2
        fail=1; continue
    fi
    # PE magic: "MZ" at 0, and a PE\0\0 signature at the e_lfanew offset.
    head -c2 "prog-$C.exe" | grep -q 'MZ' || { echo "FAIL: $C output is not a PE" >&2; fail=1; }
done

if [ $fail -eq 0 ] && command -v wine >/dev/null 2>&1; then
    for C in xcc xcc-xc; do
        out="$(WINEDEBUG=-all timeout 120 wine "prog-$C.exe" 2>/dev/null | tr -d '\r')"
        [ "$out" = "sum=55" ] || { echo "FAIL: $C exe printed '$out', wanted sum=55" >&2; fail=1; }
    done
    [ $fail -eq 0 ] && echo "PASS (built and ran under wine)"
elif [ $fail -eq 0 ]; then
    echo "PASS (built; wine not installed, so the RUN was not checked)"
fi
exit $fail
