#!/usr/bin/env bash
# wasm32-sweep.sh — corpus sweep for the wasm32 backend.
#
# Builds every applicable fixture with `xcc -A wasm32` (the full in-house
# pipeline: WAT → XTWasmWriter → .wasm + .js loader), runs each under Node
# with a per-fixture timeout, and diffs stdout against
# tests/fixtures/<name>.expected.out. No remote host, no wat2wasm.
#
# Honors the same fixture directives the in-process harness does:
#   //xtc-na: <backends> — <reason>   N/A for those backends; wasm32 is a
#                                     native-like backend, so an `arm64` (or
#                                     explicit `wasm32`) exclusion applies.
#   //xtc-flags: target=X             fixture is X-only → applies iff X=arm64.
#   //xtc-flags: -farc=off            forwarded to xcc.
#   //xtc-flags: ... skip ...         skipped.
#   //xtc-link: <name>                companion merged into the same unit.
# gfx_* fixtures are skipped by design (canvas is the web gfx layer, stage 4).
#
# Env: OPT (default 3), TIMEOUT (default 10s), NODE (default node).
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$ROOT"
XTC="bin/osx/xcc"
INC=(-I support/wasm32/lib -I support/generic/lib)
OPT="${OPT:-3}"
TIMEOUT="${TIMEOUT:-10}"
NODE="${NODE:-node}"
BUILD="$(mktemp -d)"; mkdir -p "$BUILD/bin" "$BUILD/out"
ONLY="${1:-}"   # optional: substring filter for a partial run

applies() {
  local f="$1" na tgt
  case "$(basename "$f")" in gfx*) return 1;; esac
  na="$(grep -hE '//[ ]*xtc-na:' "$f" | head -1)"
  [ -n "$na" ] && echo "$na" | grep -qE '\b(arm64|wasm32)\b' && return 1
  grep -qiE '//[ ]*xtc-flags:.*\bskip\b'   "$f" && return 1
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

# ---- 1. build ------------------------------------------------------------------
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
  if "$XTC" -q -A wasm32 "-O$OPT" $(flags_for "$f") "${INC[@]}" "$src" \
       -o "$BUILD/bin/$b" 2>"$BUILD/$b.err"; then
    NAMES+=("$b")
  else
    CFAIL=$((CFAIL+1)); CFAILS="$CFAILS $b"
  fi
done
echo "built ${#NAMES[@]}  |  N/A $NA  |  no-oracle $NOORACLE  |  compile-fail $CFAIL"

[ ${#NAMES[@]} -eq 0 ] && { echo "nothing to run"; exit 1; }

# ---- 2. run under Node ---------------------------------------------------------
for b in "${NAMES[@]}"; do
  ( cd "$BUILD/bin" && timeout "$TIMEOUT" "$NODE" "$b.js" > "../out/$b.out" 2>"../out/$b.stderr" )
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
echo "build dir kept at $BUILD (stderr + outputs per fixture)"
[ $FAIL -eq 0 ] && [ $CFAIL -eq 0 ]
