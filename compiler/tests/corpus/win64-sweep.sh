#!/usr/bin/env bash
# win64-sweep.sh — corpus sweep for the Windows x86-64 (Win64) backend.
#
# Builds every applicable fixture with `xtc -A win64`, runs the resulting static
# PE under Wine (or on a real Windows machine, XTC_WIN64_HOST=<ssh host>) with
# a per-fixture timeout, and diffs each against
# tests/fixtures/<name>.expected.out.
#
# Sibling of x86_64-sweep.sh; win64 is a native backend like arm64/x86_64, so it
# honours the same fixture directives (//xtc-na:, //xtc-flags: target=/skip/
# expect=sema/farc=off, //xtc-link:). gfx_* are skipped (GEM/SDL layer later).
#
# Env: OPT (default 3), TIMEOUT (default 15).
set -u
XC_PLAT=${XC_PLAT:-$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )}
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$ROOT"
XTC="${XTC:-bin/$XC_PLAT/xcc}"   # XTC=bin/$XC_PLAT/xcc-xc sweeps the compiler that ships
OPT="${OPT:-3}"
TIMEOUT="${TIMEOUT:-15}"
BUILD="$(mktemp -d)"; mkdir -p "$BUILD/bin" "$BUILD/out" "$BUILD/src"
# XTC_WIN64_HOST_XCC=<path on the Windows host>: that host COMPILES the
# fixtures too, with the Windows build of the compiler (an install layout:
# bin\xcc.exe beside lib\xc), in parallel across its cores. That tests the
# compiler users run on Windows, which nothing else exercises.
WXCC="${XTC_WIN64_HOST_XCC:-}"
[ -n "$WXCC" ] && [ -z "${XTC_WIN64_HOST:-}" ] && { echo "XTC_WIN64_HOST_XCC needs XTC_WIN64_HOST"; exit 2; }

ONLY="${1:-}"   # optional: substring filter for a partial run
export WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;"

applies() {
  local f="$1" na tgt
  case "$(basename "$f")" in gfx*) return 1;; esac
  na="$(grep -hE '//[ ]*xtc-na:' "$f" | head -1)"
  [ -n "$na" ] && echo "$na" | grep -qE '\b(arm64|x86_64|x86-64|win64)\b' && return 1
  grep -qiE '//[ ]*xtc-flags:.*\bskip\b'    "$f" && return 1
  grep -qiE '//[ ]*xtc-flags:.*expect=sema' "$f" && return 1
  if grep -qE '//[ ]*xtc-flags:.*target=' "$f"; then
    tgt="$(grep -hE '//[ ]*xtc-flags:.*target=' "$f" | head -1)"
    echo "$tgt" | grep -qE 'target=arm64' || return 1
  fi
  return 0
}
flags_for() { grep -qiE '//[ ]*xtc-flags:.*farc=off' "$1" && echo "-farc=off"; }
companion_for() { grep -hoE '//[ ]*xtc-link:[ ]*[A-Za-z0-9_]+' "$1" | head -1 | grep -oE '[A-Za-z0-9_]+$'; }
# Copy the fixtures a fixture imports, and theirs, into $BUILD/src. The name
# must match EXACTLY: macOS and Windows are case-insensitive, so `-f` alone
# took tests/fixtures/string.xc for the library's String.xc.
FIXTURE_NAMES=" $(ls tests/fixtures | tr '\n' ' ') "
stage_siblings() {   # stage_siblings SOURCE INTO-DIR
  local imp
  for imp in $(grep -hoE '^#(import|include)[[:space:]]+"[^"]+"' "$1" | sed -E 's/.*"([^"]+)"/\1/'); do
    case "$FIXTURE_NAMES" in *" $imp "*) ;; *) continue ;; esac
    [ -f "$2/$imp" ] && continue
    cp "tests/fixtures/$imp" "$2/$imp"
    stage_siblings "tests/fixtures/$imp" "$2"
  done
}
strip_protos() { grep -vE '^[A-Za-z_][A-Za-z0-9_@]*[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\([^){}]*\)[[:space:]]*;' "$1"; }

# ---- 1. build applicable fixtures ----------------------------------------------
NAMES=(); NA=0; CFAIL=0; NOORACLE=0; CFAILS=""
for f in tests/fixtures/*.xc; do
  b="$(basename "$f" .xc)"
  [ -n "$ONLY" ] && [[ "$b" != *"$ONLY"* ]] && continue
  [ -f "tests/fixtures/$b.expected.out" ] || { NOORACLE=$((NOORACLE+1)); continue; }
  applies "$f" || { NA=$((NA+1)); continue; }
  src="$f"; comp="$(companion_for "$f")"
  if [ -n "$comp" ] && [ -f "tests/fixtures/$comp.xc" ]; then
    src="$BUILD/$b.merged.xc"
    { strip_protos "$f"; echo; cat "tests/fixtures/$comp.xc"; } > "$src"
  fi
  if [ -n "$WXCC" ]; then
    # The Windows host compiles: stage the source and its flags.
    # Each fixture in a directory of its own, holding only what it imports:
    # Windows names are case-insensitive, and with every fixture side by side
    # the FIXTURE string.xc answered every `#import "String.xc"`.
    mkdir -p "$BUILD/src/$b"
    cp "$src" "$BUILD/src/$b/$b.xc"
    # ...and the siblings it imports (cyclic_import_a.xc, included.xc), but only
    # those: Windows names are case-insensitive, so staging every fixture let
    # tests/fixtures/string.xc stand in for the library's String.xc.
    stage_siblings "$f" "$BUILD/src/$b"
    echo "$b|$(flags_for "$f")" >> "$BUILD/src/manifest.txt"
    NAMES+=("$b")
  elif "$XTC" -A win64 -H . "-O$OPT" $(flags_for "$f") "$src" \
       -o "$BUILD/bin/$b.exe" 2>"$BUILD/$b.err"; then
    NAMES+=("$b")
  else
    CFAIL=$((CFAIL+1)); CFAILS="$CFAILS $b"
  fi
done
[ -n "$WXCC" ] && echo "staged ${#NAMES[@]} for the Windows host to compile  |  N/A $NA  |  no-oracle $NOORACLE" \
               || echo "built ${#NAMES[@]}  |  N/A $NA  |  no-oracle $NOORACLE  |  compile-fail $CFAIL"
[ ${#NAMES[@]} -eq 0 ] && { echo "nothing to run"; exit 1; }

# ---- 2. run each PE: on real Windows (XTC_WIN64_HOST), else under Wine ---------
# The Windows host is reached over ssh with PowerShell as its shell. One copy
# out, one run, one copy back. Start-Process writes the program's own bytes to
# the file (PowerShell's `>` would re-encode them as UTF-16), and reading
# $p.Handle first is what makes it keep the exit code.
WHOST="${XTC_WIN64_HOST:-}"
if [ -n "$WHOST" ]; then
  RD="xcsweep.$$"
  cat > "$BUILD/bin/run.ps1" <<'PS1'
param([string]$dir, [int]$ms, [string]$xcc = "", [int]$opt = 3, [int]$jobs = 16)
if ($xcc -eq 'none') { $xcc = '' }
if ($xcc) { $xcc = (Resolve-Path $xcc).Path }
Set-Location $dir
New-Item -ItemType Directory -Force out | Out-Null
if ($xcc) {
  # Compile every staged source with the host's own compiler, $jobs at a time.
  $running = @()
  foreach ($line in Get-Content src\manifest.txt) {
    $b, $flags = $line -split '\|', 2
    while (@($running | Where-Object { -not $_.HasExited }).Count -ge $jobs) { Start-Sleep -Milliseconds 25 }
    $a = @('-q', '-A', 'win64', "-O$opt")
    if ($flags) { $a += ($flags -split ' ') }
    $a += @("src\$b\$b.xc", '-o', "$b.exe")
    $p = Start-Process -FilePath $xcc -ArgumentList $a -RedirectStandardError "out\$b.cerr" `
           -RedirectStandardOutput "out\$b.cout" -PassThru -NoNewWindow
    $null = $p.Handle
    $p | Add-Member -NotePropertyName Fixture -NotePropertyValue $b
    $running += $p
  }
  foreach ($p in $running) { $p.WaitForExit(); Set-Content -Path "out\$($p.Fixture).crc" -Value $p.ExitCode }
}
foreach ($e in Get-ChildItem *.exe) {
  $b = $e.BaseName
  $p = Start-Process -FilePath $e.FullName -RedirectStandardOutput "out\$b.out" `
         -RedirectStandardError "out\$b.err" -PassThru -NoNewWindow
  $null = $p.Handle
  if (-not $p.WaitForExit($ms)) { $p.Kill(); $rc = 124 } else { $rc = $p.ExitCode }
  Set-Content -Path "out\$b.rc" -Value $rc
}
PS1
  ssh -o BatchMode=yes -o LogLevel=ERROR "$WHOST" "Remove-Item -Recurse -Force $RD -ErrorAction SilentlyContinue; New-Item -ItemType Directory $RD | Out-Null" \
    || { echo "ssh $WHOST failed"; exit 1; }
  scp -o BatchMode=yes -o LogLevel=ERROR -q "$BUILD/bin/"* "$WHOST:$RD/"
  [ -n "$WXCC" ] && scp -o BatchMode=yes -o LogLevel=ERROR -q -r "$BUILD/src" "$WHOST:$RD/"
  ssh -o BatchMode=yes -o LogLevel=ERROR "$WHOST" "powershell -NoProfile -ExecutionPolicy Bypass -File $RD/run.ps1 $RD $((TIMEOUT * 1000)) ${WXCC:-none} $OPT ${WIN_JOBS:-16}"
  scp -o BatchMode=yes -o LogLevel=ERROR -q -r "$WHOST:$RD/out" "$BUILD/" 2>/dev/null
  ssh -o BatchMode=yes -o LogLevel=ERROR "$WHOST" "Remove-Item -Recurse -Force $RD -ErrorAction SilentlyContinue" 2>/dev/null
else
for b in ${NAMES[@]+"${NAMES[@]}"}; do
  timeout "$TIMEOUT" wine "$BUILD/bin/$b.exe" > "$BUILD/out/$b.out" 2>/dev/null
  echo $? > "$BUILD/out/$b.rc"
done
fi

# Compiled on the Windows host: a nonzero compile status is a compile failure.
if [ -n "$WXCC" ]; then
  KEPT=()
  for b in ${NAMES[@]+"${NAMES[@]}"}; do
    rc=$(tr -d '\r\n ' < "$BUILD/out/$b.crc" 2>/dev/null)
    if [ "${rc:-1}" = 0 ]; then KEPT+=("$b"); else CFAIL=$((CFAIL+1)); CFAILS="$CFAILS $b"; fi
  done
  NAMES=(${KEPT[@]+"${KEPT[@]}"})
  echo "compiled on the Windows host: ${#KEPT[@]}  |  compile-fail $CFAIL"
fi

# ---- 3. diff against the oracles -----------------------------------------------
PASS=0; FAIL=0; FAILS=""; CRLF=""
for b in ${NAMES[@]+"${NAMES[@]}"}; do
  if diff -q "$BUILD/out/$b.out" "tests/fixtures/$b.expected.out" >/dev/null 2>&1; then
    PASS=$((PASS+1))
  elif [ -n "$WHOST" ] && tr -d '\r' < "$BUILD/out/$b.out" | diff -q - "tests/fixtures/$b.expected.out" >/dev/null 2>&1; then
    # Real Windows only: the C library's own printf (msvcrt, text mode) ends
    # lines with CR LF where xc's Stdio writes LF. Correct Windows behaviour,
    # not a difference in our code, but listed so it stays visible.
    PASS=$((PASS+1)); CRLF="$CRLF $b"
  else
    FAIL=$((FAIL+1)); FAILS="$FAILS $b"
  fi
done
echo "----------------------------------------------------------------"
echo "PASS $PASS / $((PASS+FAIL)) applicable-and-built   (N/A $NA, no-oracle $NOORACLE)"
[ -n "$CFAILS" ] && echo "compile-fail:$CFAILS"
[ -n "$FAILS" ]  && echo "run-fail:$FAILS"
[ -n "$CRLF" ]   && echo "crlf (C printf, text mode):$CRLF"
KEEP="${KEEP_BUILD:-}"; [ -n "$KEEP" ] && echo "build kept at $BUILD" || rm -rf "$BUILD"
[ $FAIL -eq 0 ] && [ $CFAIL -eq 0 ]
