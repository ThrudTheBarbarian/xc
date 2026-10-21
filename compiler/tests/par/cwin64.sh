#!/bin/bash
# cwin64.sh — the C path on real Windows: every program in tests/par/c/ (and
# tests/par/cwin/, the Windows-only ones) built
# on the Windows host by its clang -O2 alone and by the installed xcc.exe,
# which reads clang's IR (the MSVC headers', CRLF lines, LLVM 23's float
# spelling) and compiles main itself. Each xcc build must give clang's output,
# and main must be xcc's: a C path that quietly leaves main to clang gives the
# right answers too, at clang's speed, and that is what this once did on
# Windows for every program.
#
#   XTC_WIN64_HOST=<windows host> XTC_WIN64_HOST_XCC='<install>\bin\xcc.exe' bash tests/par/cwin64.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
WH=${XTC_WIN64_HOST:?the Windows host}
WX=${XTC_WIN64_HOST_XCC:?the installed xcc.exe on it, relative to its home}
SSHO="-o BatchMode=yes -o LogLevel=ERROR"
if ! ssh $SSHO "$WH" 'clang --version' >/dev/null 2>&1; then
    echo "--- cwin64: skipped (no clang on $WH) ---"
    exit 0
fi
D="xccw-c.$$"
ssh $SSHO "$WH" "Remove-Item -Recurse -Force $D -ErrorAction SilentlyContinue; New-Item -ItemType Directory $D | Out-Null" || exit 1
scp $SSHO -q tests/par/c/*.c tests/par/cwin/*.c "$WH:$D/" || { echo "--- cwin64: cannot copy the programs ---"; exit 1; }
fail=0; n=0
for f in tests/par/c/*.c tests/par/cwin/*.c; do
    b=$(basename "$f" .c)
    n=$((n + 1))
    # One PowerShell call a program: clang's build and run, then xcc's with the
    # trace of what it left to clang, then its run. Lines tagged REF/TRACE/GOT.
    out=$(ssh $SSHO "$WH" "cd $D; clang -O2 -w -o $b.ref.exe $b.c 2>&1 | Out-Null; \
          \$r = & .\\$b.ref.exe; \"REF \$r\"; \$env:XC_C_TRACE='1'; \
          cmd /c \"..\\$WX -O3 -o $b.x.exe $b.c 2>&1\" | ForEach-Object { \"TRACE \$_\" }; \
          Remove-Item Env:XC_C_TRACE; if (Test-Path $b.x.exe) { \$g = & .\\$b.x.exe; \"GOT \$g\" } else { 'GOT (no build)' }" 2>&1 | tr -d '\r')
    ref=$(printf '%s\n' "$out" | sed -n 's/^REF //p')
    got=$(printf '%s\n' "$out" | sed -n 's/^GOT //p')
    if printf '%s\n' "$out" | grep -q '^TRACE .*left to clang: @main$'; then
        echo "FAIL cwin64: $b: main was left to clang"; fail=1
    fi
    if [ -z "$ref" ] || [ "$got" != "$ref" ]; then
        echo "FAIL cwin64: $b: xcc gives '$got', clang '$ref'"
        printf '%s\n' "$out" | grep '^TRACE' | head -3
        fail=1
    fi
done
ssh $SSHO "$WH" "Remove-Item -Recurse -Force $D -ErrorAction SilentlyContinue" || true
[ $fail = 0 ] && echo "--- cwin64: pass ($n programs) ---" || echo "--- cwin64: FAIL ---"
[ $fail = 0 ]
