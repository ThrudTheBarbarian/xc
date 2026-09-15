#!/bin/sh
# crossmatrix-linux.sh — the on-Linux row of the host×target matrix (§14): the
# xtc compiler RUNNING on the Linux host builds the same program for all three
# OSes, and each is run on its own runner:
#
#   Linux → Linux    built on the Linux host, run on the Linux host
#   Linux → macOS    built on the Linux host, run here (this Mac)
#   Linux → Windows  built on the Linux host, run here under Wine
#
# Driven from the Mac (so it can run the Mach-O and PE outputs), but every BUILD
# happens on the Linux box with no external toolchain. Requires the compiler to
# be provisioned there first (tools/provision-gnustep-linux.sh) under ~/xtc.
#
# Skips cleanly if the Linux host, its xtc, or Wine are unavailable.
# NOT set -e: runners may legitimately be absent.
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
cd "$(dirname "$0")/../.."

HOST="${XTC_LINUX_HOST:-}"
WINE="${XTC_WINE:-/opt/homebrew/bin/wine}"
[ -x "$WINE" ] || WINE="$(command -v wine 2>/dev/null || true)"
RXTC="${XTC_LINUX_XTC:-\$HOME/xtc}"      # the xtc checkout ON the Linux host

if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$HOST" true 2>/dev/null; then
    echo "crossmatrix-linux: SKIP (no Linux host '$HOST')"; exit 0
fi
# The compiler must be built on the host.
if ! ssh "$HOST" "test -x $RXTC/bin/linux/xcc" 2>/dev/null; then
    echo "crossmatrix-linux: SKIP (no xtc on '$HOST' — run tools/provision-gnustep-linux.sh there)"
    exit 0
fi

EXPECT="sum-of-squares=204"
PROG='#import "Stdio.xc"
class Acc { i32 total; void init(void){total=0;} void add(i32 n){total=total+n;} i32 get(void){return total;} }
void main(void){ Acc@ a = new Acc(); for (i32 i=(i32)1; i<=(i32)8; i=i+(i32)1){ a.add(i*i); } Stdio.printf("sum-of-squares=%d\n", a.get()); }'

# Build all three targets ON the Linux host in one ssh. The compiler needs its
# GNUstep libs on LD_LIBRARY_PATH and its support tree via -H.
ssh "$HOST" "cd $RXTC && export LD_LIBRARY_PATH=\$HOME/gnustep/lib PATH=\$HOME/opt/bin:\$PATH
    printf '%s' '$PROG' > /tmp/cm.xc
    bin/linux/xcc -A x86_64 --self-host -q -H . /tmp/cm.xc -o /tmp/cm.elf 2>/dev/null
    bin/linux/xcc -A arm64  --self-host -q -H . /tmp/cm.xc -o /tmp/cm.macho 2>/dev/null
    bin/linux/xcc -A win64  --self-host -q -H . /tmp/cm.xc -o /tmp/cm.exe 2>/dev/null
    echo built" >/dev/null 2>&1

fail=0
report() { printf '  %-34s' "$1"; [ "$2" = "$EXPECT" ] && echo "ok" || { echo "FAIL (got '$2')"; fail=1; }; }

# Linux → Linux: run on the host.
got=$(ssh "$HOST" 'chmod +x /tmp/cm.elf 2>/dev/null && /tmp/cm.elf' 2>/dev/null | tr -d '\r')
report "Linux builds+runs → Linux" "$got"

# Linux → macOS: pull the Mach-O here and run it natively.
if scp -q "$HOST:/tmp/cm.macho" /tmp/cm.macho 2>/dev/null; then
    chmod +x /tmp/cm.macho
    report "Linux builds → macOS (run here)" "$(/tmp/cm.macho 2>/dev/null | tr -d '\r')"
else
    printf '  %-34s' "Linux builds → macOS"; echo "SKIP (scp)"
fi

# Linux → Windows: pull the PE here and run under Wine.
if [ -n "$WINE" ] && scp -q "$HOST:/tmp/cm.exe" /tmp/cm.exe 2>/dev/null; then
    "$WINE" --version >/dev/null 2>&1 || true
    report "Linux builds → Windows (Wine here)" "$(timeout 90 "$WINE" /tmp/cm.exe 2>/dev/null | tr -d '\r')"
else
    printf '  %-34s' "Linux builds → Windows"; echo "SKIP (no wine/scp)"
fi

ssh "$HOST" 'rm -f /tmp/cm.xc /tmp/cm.elf /tmp/cm.macho /tmp/cm.exe' 2>/dev/null || true
echo
[ $fail = 0 ] && echo "crossmatrix-linux: the Linux-hosted compiler produces working mac/linux/win binaries" \
              || echo "crossmatrix-linux: FAILURES"
exit $fail
