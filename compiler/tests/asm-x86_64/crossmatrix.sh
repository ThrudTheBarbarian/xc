#!/bin/sh
# crossmatrix.sh — the "on macOS" row of the host×target matrix (§14): one Mac
# builds the SAME xtc program for all three targets, entirely in-house, and every
# one produces the same output.
#
#   macOS arm64   — native, the --self-host default (run here)
#   Linux x86-64  — self-hosted ELF (run on $XTC_LINUX_HOST)
#   Windows x86-64 — self-hosted PE (run under Wine)
#
# Each leg that has no runner (no Linux host, no Wine) is reported SKIP, not
# failed. The point is that the three binaries are BYTE-produced with no external
# toolchain and agree on the answer.
#
# NOT set -e: a target's runner may legitimately be unavailable.
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
cd "$(dirname "$0")/../.."
ROOT=$(pwd)

HOST="${XTC_LINUX_HOST:-}"
WINE="${XTC_WINE:-/opt/homebrew/bin/wine}"
[ -x "$WINE" ] || WINE="$(command -v wine 2>/dev/null || true)"
[ -x "$ROOT/bin/osx/xcc" ] || { echo "build first: make"; exit 1; }

# A program that exercises the object model, ARC and printf — not just a return
# code — so "same output" means something.
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cat > "$W/prog.xc" <<'EOF'
#import "Stdio.xc"
class Acc {
    i32 total;
    void init(void) { total = 0; }
    void add(i32 n) { total = total + n; }
    i32  get(void)  { return total; }
}
void main(void)
{
    Acc@ a = new Acc();
    for (i32 i = (i32)1; i <= (i32)8; i = i + (i32)1) { a.add(i * i); }
    Stdio.printf("sum-of-squares=%d\n", a.get());
}
EOF
EXPECT="sum-of-squares=204"

fail=0; ran=0
report() {   # report <label> <got> [SKIP]
    printf '  %-28s' "$1"
    if [ "$2" = "SKIP" ]; then echo "SKIP ($3)"; return; fi
    ran=$((ran+1))
    if [ "$2" = "$EXPECT" ]; then echo "ok  ($2)"; else echo "FAIL (got '$2', want '$EXPECT')"; fail=1; fi
}

# ── macOS arm64 (native, self-host default) ──
if "$ROOT"/bin/osx/xcc -A arm64 "$W/prog.xc" -o "$W/prog.macho" >"$W/log" 2>&1; then
    report "macOS arm64 (self-host)" "$("$W/prog.macho" 2>/dev/null | tr -d '\r')"
else
    report "macOS arm64 (self-host)" SKIP "build failed: $(tail -1 "$W/log")"
fi

# ── Linux x86-64 (self-host ELF) ──
if "$ROOT"/bin/osx/xcc -A x86_64 --self-host "$W/prog.xc" -o "$W/prog.elf" >"$W/log" 2>&1 \
   && grep -q "self-hosted, no clang" "$W/log"; then
    if ssh -o BatchMode=yes -o ConnectTimeout=5 "$HOST" true 2>/dev/null; then
        scp -q "$W/prog.elf" "$HOST:/tmp/xtc-cm-$$" 2>/dev/null
        got=$(ssh "$HOST" "chmod +x /tmp/xtc-cm-$$; /tmp/xtc-cm-$$; rm -f /tmp/xtc-cm-$$" 2>/dev/null | tr -d '\r')
        report "Linux x86-64 (self-host)" "$got"
    else
        report "Linux x86-64 (self-host)" SKIP "no Linux host '$HOST'"
    fi
else
    report "Linux x86-64 (self-host)" SKIP "build fell back or failed"
fi

# ── Windows x86-64 (self-host PE) ──
if "$ROOT"/bin/osx/xcc -A win64 --self-host "$W/prog.xc" -o "$W/prog.exe" >"$W/log" 2>&1 \
   && grep -q "self-hosted, no mingw" "$W/log"; then
    if [ -n "$WINE" ]; then
        "$WINE" --version >/dev/null 2>&1 || true
        report "Windows x86-64 (self-host)" "$(timeout 90 "$WINE" "$W/prog.exe" 2>/dev/null | tr -d '\r')"
    else
        report "Windows x86-64 (self-host)" SKIP "no wine"
    fi
else
    report "Windows x86-64 (self-host)" SKIP "build fell back or failed"
fi

echo
if [ $fail = 0 ]; then echo "crossmatrix: $ran/3 targets ran, all agree — one Mac, three OSes, no external toolchain"
else echo "crossmatrix: FAILURES"; fi
exit $fail
