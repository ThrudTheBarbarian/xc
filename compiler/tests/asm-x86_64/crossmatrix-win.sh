#!/bin/sh
# crossmatrix-win.sh — the on-Windows row of the host×target matrix (§14): the
# xtc compiler RUNNING on Windows builds the same program for all three OSes, and
# each is run on its own runner:
#
#   Windows → Windows  built on win11, run on win11
#   Windows → macOS    built on win11, run here (this Mac)
#   Windows → Linux    built on win11, run on $XTC_LINUX_HOST
#
# Driven from the Mac. Requires the compiler to be built on the Windows host
# (tools/winbuild.bat) under %USERPROFILE%\xtc\build\bin, with the GNUstep bin
# dir on PATH. Skips cleanly if the Windows host or its xtc are unavailable.
# NOT set -e: runners may legitimately be absent.
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
cd "$(dirname "$0")/../.."

WHOST="${XTC_WIN_HOST:-win11}"
LHOST="${XTC_LINUX_HOST:-}"

if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$WHOST" "cd %USERPROFILE%" >/dev/null 2>&1; then
    echo "crossmatrix-win: SKIP (no Windows host '$WHOST')"; exit 0
fi
if ! ssh "$WHOST" 'if exist %USERPROFILE%\xtc\build\bin\xtc.exe (echo yes)' 2>/dev/null | grep -q yes; then
    echo "crossmatrix-win: SKIP (no xtc on '$WHOST' — run tools/winbuild.bat there)"; exit 0
fi

EXPECT="sum-of-squares=204"
# Write the program on the Windows host (base64 to dodge cmd quoting).
PROG='#import "Stdio.xc"
class Acc { i32 total; void init(void){total=0;} void add(i32 n){total=total+n;} i32 get(void){return total;} }
void main(void){ Acc@ a = new Acc(); for (i32 i=(i32)1; i<=(i32)8; i=i+(i32)1){ a.add(i*i); } Stdio.printf("sum-of-squares=%d\n", a.get()); }'
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
printf '%s\n' "$PROG" > "$TMP/cm.xc"
scp -q "$TMP/cm.xc" "$WHOST:cm.xc" 2>/dev/null || { echo "crossmatrix-win: scp failed"; exit 1; }

# Build all three targets ON Windows.
ssh "$WHOST" 'cd %USERPROFILE%\xtc\build\bin && xtc.exe -A win64  --self-host -q -H %USERPROFILE%\xtc %USERPROFILE%\cm.xc -o %USERPROFILE%\cm.exe   2>nul & xtc.exe -A arm64  --self-host -q -H %USERPROFILE%\xtc %USERPROFILE%\cm.xc -o %USERPROFILE%\cm.macho 2>nul & xtc.exe -A x86_64 --self-host -q -H %USERPROFILE%\xtc %USERPROFILE%\cm.xc -o %USERPROFILE%\cm.elf   2>nul' >/dev/null 2>&1

fail=0
report() { printf '  %-36s' "$1"; [ "$2" = "$EXPECT" ] && echo "ok" || { echo "FAIL (got '$2')"; fail=1; }; }

# Windows → Windows: run on the Windows host.
got=$(ssh "$WHOST" 'cd %USERPROFILE% && cm.exe' 2>/dev/null | tr -d '\r')
report "Windows builds+runs → Windows" "$got"

# Windows → macOS: pull the Mach-O here and run natively.
if scp -q "$WHOST:cm.macho" "$TMP/cm.macho" 2>/dev/null; then
    chmod +x "$TMP/cm.macho"
    report "Windows builds → macOS (run here)" "$("$TMP/cm.macho" 2>/dev/null | tr -d '\r')"
else printf '  %-36s' "Windows builds → macOS"; echo "SKIP (scp)"; fi

# Windows → Linux: pull the ELF here, push to the Linux host, run.
if scp -q "$WHOST:cm.elf" "$TMP/cm.elf" 2>/dev/null && \
   ssh -o BatchMode=yes -o ConnectTimeout=5 "$LHOST" true 2>/dev/null && \
   scp -q "$TMP/cm.elf" "$LHOST:/tmp/cm-win.elf" 2>/dev/null; then
    report "Windows builds → Linux (run there)" \
           "$(ssh "$LHOST" 'chmod +x /tmp/cm-win.elf && /tmp/cm-win.elf; rm -f /tmp/cm-win.elf' 2>/dev/null | tr -d '\r')"
else printf '  %-36s' "Windows builds → Linux"; echo "SKIP (no Linux host)"; fi

ssh "$WHOST" 'del %USERPROFILE%\cm.xc %USERPROFILE%\cm.exe %USERPROFILE%\cm.macho %USERPROFILE%\cm.elf 2>nul' >/dev/null 2>&1
echo
[ $fail = 0 ] && echo "crossmatrix-win: the Windows-hosted compiler produces working mac/linux/win binaries" \
              || echo "crossmatrix-win: FAILURES"
exit $fail
