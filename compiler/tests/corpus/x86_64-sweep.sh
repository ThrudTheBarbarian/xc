#!/usr/bin/env bash
# x86_64-sweep.sh — corpus sweep for the x86-64 backend.
#
# Builds every applicable fixture locally with `xtc -A x86_64`, ships the static
# musl ELFs to a real Linux x86-64 host (XTC_X86_64_HOST, or XTC_LINUX_HOST) in ONE batch, runs
# them there with a per-fixture timeout, tars the outputs back, and diffs each
# against tests/fixtures/<name>.expected.out.
#
# Honors the same fixture directives the in-process harness (XTCorpusSweep) does:
#   //xtc-na: <backends> — <reason>   fixture N/A for those backends. x86-64 is a
#                                     native backend like arm64, so an `arm64` (or
#                                     explicit `x86_64`) exclusion applies here too.
#   //xtc-flags: target=X             fixture is X-only → applies iff X is arm64.
#   //xtc-flags: -farc=off            forwarded to xtc (manual lifecycle).
#   //xtc-flags: ... skip ...         skipped.
#   //xtc-link: <name>                companion compiled into the same unit.
# gfx_* fixtures are skipped by design (GEM/SDL3 will be the x86-64 gfx layer).
#
# Env: XTC_X86_64_HOST (falls back to XTC_LINUX_HOST), OPT (default 3), TIMEOUT (default 10).
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$ROOT"
XTC="bin/osx/xcc"
INC=(-I support/x86_64/lib -I support/generic/lib)
HOST="${XTC_X86_64_HOST:-${XTC_LINUX_HOST:-}}"
OPT="${OPT:-3}"
TIMEOUT="${TIMEOUT:-10}"
REMOTE="/tmp/x86sweep.$$"
BUILD="$(mktemp -d)"; mkdir -p "$BUILD/bin" "$BUILD/out"
ONLY="${1:-}"   # optional: substring filter for a partial run

# Is this fixture applicable to the x86-64 backend?
applies() {
  local f="$1" na tgt
  case "$(basename "$f")" in gfx*) return 1;; esac         # gfx → GEM/SDL3 later
  na="$(grep -hE '//[ ]*xtc-na:' "$f" | head -1)"
  [ -n "$na" ] && echo "$na" | grep -qE '\b(arm64|x86_64|x86-64)\b' && return 1
  grep -qiE '//[ ]*xtc-flags:.*\bskip\b'   "$f" && return 1
  grep -qiE '//[ ]*xtc-flags:.*expect=sema' "$f" && return 1
  if grep -qE '//[ ]*xtc-flags:.*target=' "$f"; then       # X-only → x86-64 iff X=arm64
    tgt="$(grep -hE '//[ ]*xtc-flags:.*target=' "$f" | head -1)"
    echo "$tgt" | grep -qE 'target=arm64' || return 1
  fi
  return 0
}
flags_for() { grep -qiE '//[ ]*xtc-flags:.*farc=off' "$1" && echo "-farc=off"; }
companion_for() { grep -hoE '//[ ]*xtc-link:[ ]*[A-Za-z0-9_]+' "$1" | head -1 | grep -oE '[A-Za-z0-9_]+$'; }
# Drop function-prototype lines (`type name(...);`, trailing comment allowed) so the
# caller's forward decls don't collide with the companion's definitions when merged.
# Mirrors XTCorpusSweep's stripFunctionPrototypes (no end anchor — matches the prefix).
strip_protos() { grep -vE '^[A-Za-z_][A-Za-z0-9_@]*[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\([^){}]*\)[[:space:]]*;' "$1"; }

# ---- 1. build applicable fixtures ----------------------------------------------
NAMES=(); NA=0; CFAIL=0; NOORACLE=0; CFAILS=""
for f in tests/fixtures/*.xc; do
  b="$(basename "$f" .xc)"
  [ -n "$ONLY" ] && [[ "$b" != *"$ONLY"* ]] && continue
  [ -f "tests/fixtures/$b.expected.out" ] || { NOORACLE=$((NOORACLE+1)); continue; }
  applies "$f" || { NA=$((NA+1)); continue; }
  # //xtc-link: the new-IR path is single-file, so "link" by merging the pair into
  # one unit (strip the caller's prototypes, append the companion's definitions) —
  # exactly what the in-process harness does for the whole-program backends.
  src="$f"; comp="$(companion_for "$f")"
  if [ -n "$comp" ] && [ -f "tests/fixtures/$comp.xc" ]; then
    src="$BUILD/$b.merged.xc"
    { strip_protos "$f"; echo; cat "tests/fixtures/$comp.xc"; } > "$src"
  fi
  if "$XTC" -A x86_64 "-O$OPT" $(flags_for "$f") "${INC[@]}" "$src" \
       -o "$BUILD/bin/$b" 2>"$BUILD/$b.err"; then
    NAMES+=("$b")
  else
    CFAIL=$((CFAIL+1)); CFAILS="$CFAILS $b"
  fi
done
echo "built ${#NAMES[@]}  |  N/A $NA  |  no-oracle $NOORACLE  |  compile-fail $CFAIL"

[ ${#NAMES[@]} -eq 0 ] && { echo "nothing to run"; exit 1; }

# ---- 2. ship + run on the Linux host (one scp, one ssh) ------------------------
ssh -o BatchMode=yes "$HOST" "rm -rf $REMOTE && mkdir -p $REMOTE/out" || { echo "ssh $HOST failed"; exit 1; }
scp -o BatchMode=yes -q "$BUILD/bin/"* "$HOST:$REMOTE/"
ssh -o BatchMode=yes "$HOST" \
  "cd $REMOTE; for b in *; do timeout $TIMEOUT ./\$b > out/\$b.out 2>/dev/null; echo \$? > out/\$b.rc; done; tar cf - -C out ." \
  | tar xf - -C "$BUILD/out"
ssh -o BatchMode=yes "$HOST" "rm -rf $REMOTE" 2>/dev/null

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
rm -rf "$BUILD"
[ $FAIL -eq 0 ] && [ $CFAIL -eq 0 ]
