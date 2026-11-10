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
# Env: XTC_X86_64_HOST (falls back to XTC_LINUX_HOST), XTC (default bin/$XC_PLAT/xcc),
#      OPT (default 3), TIMEOUT (default 10).
XC_PLAT=${XC_PLAT:-$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )}
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$ROOT"
XTC="${XTC:-bin/$XC_PLAT/xcc}"   # XTC=bin/$XC_PLAT/xcc-xc sweeps the compiler that ships
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
# RUN_ENV is set for every run, e.g. RUN_ENV=XC_SIMD=base to run a -msimd=auto
# corpus on its base variants on a machine that would pick AVX2.
# SWEEP_FLAGS is added to every compile, e.g. SWEEP_FLAGS=-mavx2 to run the
# whole corpus at the 256-bit vector level.
flags_for() {
  local fl=""
  grep -qiE '//[ ]*xtc-flags:.*farc=off' "$1" && fl="-farc=off"
  echo $fl ${SWEEP_FLAGS:-}
}
companion_for() { grep -hoE '//[ ]*xtc-link:[ ]*[A-Za-z0-9_]+' "$1" | head -1 | grep -oE '[A-Za-z0-9_]+$'; }
# Drop function-prototype lines (`type name(...);`, trailing comment allowed) so the
# caller's forward decls don't collide with the companion's definitions when merged.
# Mirrors XTCorpusSweep's stripFunctionPrototypes (no end anchor — matches the prefix).
strip_protos() { grep -vE '^[A-Za-z_][A-Za-z0-9_@]*[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\([^){}]*\)[[:space:]]*;' "$1"; }

# ---- 1. build applicable fixtures ----------------------------------------------
# In parallel (SWEEP_JOBS, default the host's CPUs over 4, since the gate runs
# several legs on one host): a fixture whose loop the compiler lifts brings
# the par runtime in, which takes seconds to compile, and 160 of them one
# after another outran the gate's two hours. Results are read back in fixture
# order, so the counts and the run order are what a serial build gives.
JOBS="${SWEEP_JOBS:-$(( $( (nproc || sysctl -n hw.ncpu) 2>/dev/null || echo 4) / 4 ))}"
[ "$JOBS" -ge 1 ] 2>/dev/null || JOBS=1
NAMES=(); NA=0; CFAIL=0; NOORACLE=0; CFAILS=""; TRIED=()
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
  TRIED+=("$b")
  while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n 2>/dev/null || sleep 0.1; done
  ( if "$XTC" -A x86_64 "-O$OPT" $(flags_for "$f") "${INC[@]}" "$src" \
         -o "$BUILD/bin/$b" 2>"$BUILD/$b.err"; then : > "$BUILD/$b.built"; fi ) &
done
wait
for b in ${TRIED[@]+"${TRIED[@]}"}; do
  if [ -f "$BUILD/$b.built" ]; then
    NAMES+=("$b")
  else
    rm -f "$BUILD/bin/$b"; CFAIL=$((CFAIL+1)); CFAILS="$CFAILS $b"
  fi
done
echo "built ${#NAMES[@]}  |  N/A $NA  |  no-oracle $NOORACLE  |  compile-fail $CFAIL"

[ ${#NAMES[@]} -eq 0 ] && { echo "nothing to run"; exit 1; }

# ---- 2. run them: here when this IS an x86-64 Linux host, else ship them -------
# The private HOME below holds settings and par auto's learned choices. The GPU
# drivers' compiled-shader caches stay in the user's real cache directories:
# with an empty cache a Vulkan driver can spend seconds compiling a par block's
# kernels before the first result (several seconds per kernel on an integrated
# Radeon), and on a loaded host that outruns the per-fixture timeout. The
# remote form is expanded by the remote shell, before env replaces its HOME.
GPU_CACHES=("XDG_CACHE_HOME=${XDG_CACHE_HOME:-$HOME/.cache}"
            "CUDA_CACHE_PATH=${CUDA_CACHE_PATH:-$HOME/.nv/ComputeCache}")
GPU_CACHES_REMOTE='XDG_CACHE_HOME=${XDG_CACHE_HOME:-$HOME/.cache} CUDA_CACHE_PATH=${CUDA_CACHE_PATH:-$HOME/.nv/ComputeCache}'

# HOST=local (or no host on an x86-64 Linux machine) runs in place, which is
# what the CI's Linux worker does; anything else is one scp and one ssh.
if [ "$HOST" = local ] || { [ -z "$HOST" ] && [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ]; }; then
  # A private HOME (and XDG config dir) per sweep: settings_standard keeps a
  # file there, and the gate runs several x86-64 legs on one host at once.
  # The GPU drivers' shader caches stay the user's own (see GPU_CACHES).
  mkdir -p "$BUILD/home/.config"
  ( cd "$BUILD/bin" && for b in *; do env HOME="$BUILD/home" XDG_CONFIG_HOME="$BUILD/home/.config" "${GPU_CACHES[@]}" ${RUN_ENV:-} timeout "$TIMEOUT" ./"$b" > "$BUILD/out/$b.out" 2>/dev/null; echo $? > "$BUILD/out/$b.rc"; done )
else
[ -n "$HOST" ] || { echo "no x86-64 Linux host: set XTC_X86_64_HOST (or run on one)"; exit 1; }
ssh -o BatchMode=yes "$HOST" "rm -rf $REMOTE && mkdir -p $REMOTE/out" || { echo "ssh $HOST failed"; exit 1; }
scp -o BatchMode=yes -q "$BUILD/bin/"* "$HOST:$REMOTE/"
ssh -o BatchMode=yes "$HOST" \
  "cd $REMOTE; mkdir -p .home/.config; for b in *; do env HOME=$REMOTE/.home XDG_CONFIG_HOME=$REMOTE/.home/.config $GPU_CACHES_REMOTE ${RUN_ENV:-} timeout $TIMEOUT ./\$b > out/\$b.out 2>/dev/null; echo \$? > out/\$b.rc; done; tar cf - -C out ." \
  | tar xf - -C "$BUILD/out"
ssh -o BatchMode=yes "$HOST" "rm -rf $REMOTE" 2>/dev/null
fi

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
