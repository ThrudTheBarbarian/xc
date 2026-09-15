#!/usr/bin/env bash
# win64-sweep.sh — corpus sweep for the Windows x86-64 (Win64) backend.
#
# Builds every applicable fixture with `xtc -A win64`, runs the resulting static
# PE locally under Wine with a per-fixture timeout, and diffs each against
# tests/fixtures/<name>.expected.out.
#
# Sibling of x86_64-sweep.sh; win64 is a native backend like arm64/x86_64, so it
# honours the same fixture directives (//xtc-na:, //xtc-flags: target=/skip/
# expect=sema/farc=off, //xtc-link:). gfx_* are skipped (GEM/SDL layer later).
#
# Env: OPT (default 3), TIMEOUT (default 15).
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$ROOT"
XTC="bin/osx/xcc"
OPT="${OPT:-3}"
TIMEOUT="${TIMEOUT:-15}"
BUILD="$(mktemp -d)"; mkdir -p "$BUILD/bin" "$BUILD/out"
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
  if "$XTC" -A win64 -H . "-O$OPT" $(flags_for "$f") "$src" \
       -o "$BUILD/bin/$b.exe" 2>"$BUILD/$b.err"; then
    NAMES+=("$b")
  else
    CFAIL=$((CFAIL+1)); CFAILS="$CFAILS $b"
  fi
done
echo "built ${#NAMES[@]}  |  N/A $NA  |  no-oracle $NOORACLE  |  compile-fail $CFAIL"
[ ${#NAMES[@]} -eq 0 ] && { echo "nothing to run"; exit 1; }

# ---- 2. run each PE under Wine -------------------------------------------------
for b in "${NAMES[@]}"; do
  timeout "$TIMEOUT" wine "$BUILD/bin/$b.exe" > "$BUILD/out/$b.out" 2>/dev/null
  echo $? > "$BUILD/out/$b.rc"
done

# ---- 3. diff against the oracles -----------------------------------------------
PASS=0; FAIL=0; FAILS=""
for b in "${NAMES[@]}"; do
  if diff -q "$BUILD/out/$b.out" "tests/fixtures/$b.expected.out" >/dev/null 2>&1; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); FAILS="$FAILS $b"
  fi
done
echo "----------------------------------------------------------------"
echo "PASS $PASS / $((PASS+FAIL)) applicable-and-built   (N/A $NA, no-oracle $NOORACLE)"
[ -n "$CFAILS" ] && echo "compile-fail:$CFAILS"
[ -n "$FAILS" ]  && echo "run-fail:$FAILS"
KEEP="${KEEP_BUILD:-}"; [ -n "$KEEP" ] && echo "build kept at $BUILD" || rm -rf "$BUILD"
[ $FAIL -eq 0 ] && [ $CFAIL -eq 0 ]
