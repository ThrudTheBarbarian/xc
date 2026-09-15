#!/bin/sh
# selfhost-win64.sh — the self-hosted Windows path end to end: xtc → the shared
# x86-64 backend → XAX86_64Assembler → XTPEWriter, run under Wine. No mingw, no
# lld-link, no Windows SDK anywhere.
#
# Needs Wine on PATH (or set XTC_WINE). Skips cleanly if it is absent.
# NOT set -e: the exit-status test deliberately runs a program that exits 42.
cd "$(dirname "$0")/../.."
ROOT=$(pwd)

WINE="${XTC_WINE:-/opt/homebrew/bin/wine}"
[ -x "$WINE" ] || WINE="$(command -v wine 2>/dev/null || true)"
[ -x "$ROOT/bin/osx/xcc" ] || { echo "build first: make"; exit 1; }
if [ -z "$WINE" ]; then echo "selfhost-win64: SKIP (no wine)"; exit 0; fi

# A Wine prefix runs its first program slowly (it initialises); prime it once so
# the per-test timeouts below are about our code, not Wine's setup.
"$WINE" --version >/dev/null 2>&1 || true

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
fail=0
check() {   # check <name> <exe> <expected-fixture-or-status>
    printf '  %-40s' "$1"
    if [ "$3" = "@status42" ]; then
        timeout 90 "$WINE" "$2" >/dev/null 2>&1; st=$?
        [ "$st" = 42 ] && echo "ok" || { echo "FAIL (exit $st, want 42)"; fail=1; }
    else
        got=$(timeout 90 "$WINE" "$2" 2>/dev/null | tr -d '\r')
        [ "$got" = "$(tr -d '\r' < "$3")" ] && echo "ok" || { echo "FAIL"; fail=1; }
    fi
}

# 1. exit status through a real kernel32 import.
cat > "$W/ret42.xc" <<'EOF'
i32 main() (( return 42; ))
EOF
"$ROOT"/bin/osx/xcc -A win64 --self-host "$W/ret42.xc" -o "$W/ret42.exe" >"$W/log" 2>&1
grep -q "self-hosted, no mingw" "$W/log" || { echo "  ret42 fell back to mingw"; fail=1; }
check "exit status via ExitProcess" "$W/ret42.exe" "@status42"

# 2. printf — the runtime's write() through kernel32.
"$ROOT"/bin/osx/xcc -A win64 --self-host tests/fixtures/hello.xc -o "$W/hello.exe" >"$W/log" 2>&1
grep -q "self-hosted, no mingw" "$W/log" || { echo "  hello fell back to mingw"; fail=1; }
check "printf output" "$W/hello.exe" tests/fixtures/hello.expected.out

# 3. heap + vtable + ARC — the case that null-called on the first attempt (#757).
"$ROOT"/bin/osx/xcc -A win64 --self-host tests/fixtures/printf_class.xc -o "$W/pc.exe" >"$W/log" 2>&1
grep -q "self-hosted, no mingw" "$W/log" || { echo "  printf_class fell back to mingw"; fail=1; }
check "heap + vtable + ARC" "$W/pc.exe" tests/fixtures/printf_class.expected.out

[ $fail = 0 ] && echo "selfhost-win64: all ok" || echo "selfhost-win64: FAILURES"
exit $fail
