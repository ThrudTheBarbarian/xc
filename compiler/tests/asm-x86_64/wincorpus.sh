#!/bin/sh
# wincorpus.sh — run the deterministic, self-contained fixture corpus through the
# Windows-NATIVE compiler (win64 self-host), byte-comparing each program's output
# against its .expected.out. The counterpart of selfhost-corpus.sh, for the
# on-Windows path.
#
# Driven from here; the compiler must already be built on the Windows host
# (tools/winbuild.bat) under %USERPROFILE%\xtc\build\bin, with the GNUstep bin dir
# on PATH. Skips cleanly if the host or its xtc is unavailable.
#
# Fixture selection mirrors the other self-host corpora: drop skip/target=/
# //xtc-na:x86_64/ //xtc-link:/ -farc=off, and additionally drop #include
# companions (not shipped) and the wall-clock timing fixture (non-deterministic).
set -e
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
WHOST="${XTC_WIN_HOST:-win11}"

if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$WHOST" "cd %USERPROFILE%" >/dev/null 2>&1; then
    echo "wincorpus: SKIP (no Windows host '$WHOST')"; exit 0
fi
if ! ssh "$WHOST" 'if exist %USERPROFILE%\xtc\build\bin\xtc.exe (echo yes)' 2>/dev/null | grep -q yes; then
    echo "wincorpus: SKIP (no xtc on '$WHOST' — run tools/winbuild.bat there)"; exit 0
fi

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
n=0
for f in tests/fixtures/*.xc; do
    b=$(basename "$f" .xc)
    [ -f "tests/fixtures/$b.expected.out" ] || continue
    grep -qE '^//xtc-flags:.*(skip|target=)' "$f" && continue
    grep -E '^//xtc-na:' "$f" 2>/dev/null | grep -q 'x86_64' && continue
    grep -q '^//xtc-link:' "$f" && continue
    grep -q '\-farc=off' "$f" && continue
    grep -q '#include' "$f" && continue             # companion files not shipped
    [ "$b" = time_elapsed ] && continue             # wall-clock, non-deterministic
    [ "$b" = auto_cloak ]   && continue             # xe-family cloaking
    cp "$f" "$W/$b.xc"; cp "tests/fixtures/$b.expected.out" "$W/$b.expected"; n=$((n+1))
done
echo "wincorpus: $n fixtures"

# The batch that compiles+runs+compares, run on the Windows host.
cat > "$W/run.bat" <<'BAT'
@echo off
setlocal enabledelayedexpansion
set XTC=%USERPROFILE%\xtc\build\bin\xtc.exe
cd %USERPROFILE%\wincorpus
set pass=0& set fail=0& set build=0
for %%f in (*.xc) do (
  %XTC% -A win64 --self-host -q -H %USERPROFILE%\xtc "%%f" -o "%%~nf.exe" 2>nul
  if exist "%%~nf.exe" (
    "%%~nf.exe" > "%%~nf.got" 2>nul
    fc /b "%%~nf.got" "%%~nf.expected" >nul 2>&1
    if !errorlevel! equ 0 (set /a pass+=1) else (set /a fail+=1& echo DIFF %%~nf)
    del "%%~nf.exe" "%%~nf.got" 2>nul
  ) else (set /a build+=1& echo BUILDFAIL %%~nf)
)
echo === wincorpus: !pass! pass, !fail! diff, !build! buildfail ===
BAT

tar czf "$W/wc.tgz" -C "$W" . 2>/dev/null
scp -q "$W/wc.tgz" "$WHOST:wc.tgz" || { echo "wincorpus: scp failed"; exit 1; }
ssh "$WHOST" 'cd %USERPROFILE% && (if exist wincorpus rmdir /s /q wincorpus) & mkdir wincorpus & cd wincorpus & tar xzf ..\wc.tgz' >/dev/null 2>&1
ssh "$WHOST" 'cd %USERPROFILE% && wincorpus\run.bat' 2>/dev/null | tr -d '\r' | grep -E "wincorpus:|DIFF|BUILDFAIL"
ssh "$WHOST" 'rmdir /s /q %USERPROFILE%\wincorpus & del %USERPROFILE%\wc.tgz' >/dev/null 2>&1
