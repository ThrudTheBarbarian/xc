#!/bin/bash
# m68k-sweep.sh — every fixture built for the Atari ST by the shipped compiler,
# at -O0 and at -O2, run on the 68000 simulator (xcc-sim-68k) and compared with
# its expected output: `<name>.expected.atarist.out` where the ST answers
# differently (big-endian, two-byte alignment), else `<name>.expected.out`.
#
# A fixture is skipped where its `//xtc-na:` list (the targets before the dash)
# names m68k, where it is marked skip or expect=sema, or where a `target=`
# restricts it to another target. One that does not BUILD is counted apart and
# not failed: the ST lacks threads, sockets, the par runtime and C's libc by
# design, and those fixtures stop at compile time. A wrong answer, a crash and a
# run past the time limit are failures, and each says which: FAIL(timeout),
# FAIL(crash: signal N), FAIL(exit N, wrong output) or FAIL(wrong output). The
# heaviest fixtures (the SME matrix multiplies) take about 25 s at -O0 on a
# loaded host, so the default limit leaves them little room.
#
#   bash tests/corpus/m68k-sweep.sh [filter]     (from compiler/)
# Env: XCC (default bin/<plat>/xcc-xc), SIM (bin/<plat>/xcc-sim-68k),
#      JOBS (default CPUs/4), TIMEOUT (seconds per run, default 30),
#      KNOWN (an ERE of fixture names whose failure is expected and filed).
set -u
XC_PLAT=${XC_PLAT:-$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )}
cd "$(dirname "$0")/../.." || exit 1
XCC=${XCC:-bin/$XC_PLAT/xcc-xc}
SIM=${SIM:-bin/$XC_PLAT/xcc-sim-68k}
[ -x "$XCC" ] || { echo "m68k-sweep: no compiler at $XCC"; exit 1; }
[ -x "$SIM" ] || { echo "m68k-sweep: no simulator at $SIM"; exit 1; }
# Each program runs in the scratch directory (its files land there), so the
# simulator is named by an absolute path.
case "$SIM" in /*) ;; *) SIM="$PWD/$SIM" ;; esac
JOBS=${JOBS:-$(( $( (nproc || sysctl -n hw.ncpu) 2>/dev/null || echo 4) / 4 ))}
[ "$JOBS" -ge 1 ] 2>/dev/null || JOBS=1
TIMEOUT=${TIMEOUT:-30}
ONLY=${1:-}
W=$(mktemp -d "${TMPDIR:-/tmp}/m68k-sweep.XXXXXX")
trap 'rm -rf "$W"' EXIT
# A time limit without coreutils' timeout (macOS has none by default).
limit() { perl -e 'alarm shift; exec @ARGV or exit 127' "$@"; }

one() {  # <fixture> -> one result line
    f=$1; b=$(basename "$f" .xc)
    exp=tests/fixtures/$b.expected.atarist.out
    [ -f "$exp" ] || exp=tests/fixtures/$b.expected.out
    [ -f "$exp" ] || return 0
    grep -qiE '//[ ]*xtc-flags:.*\bskip\b' "$f" && return 0
    grep -qiE '//[ ]*xtc-flags:.*expect=sema' "$f" && return 0
    tgt=$(grep -hoE '//[ ]*xtc-flags:.*target=[A-Za-z0-9_]+' "$f" | head -1 | sed 's/.*target=//')
    case "$tgt" in ""|both|arm64|atarist|m68k) ;; *) return 0 ;; esac
    na=$(grep -hE '//[ ]*xtc-na:' "$f" | head -1 | sed -e 's/.*xtc-na:[[:space:]]*//' -e 's/—.*//' -e 's/--.*//' -e 's/[[:space:]]//g')
    printf ',%s,' "$na" | grep -qE ',(m68k|atarist|68k|68000|68030),' && return 0
    r="$b"
    for O in 0 2; do
        if ! limit 300 "$XCC" -q -O$O -A atarist -H . -o "$W/$b.$O.prg" "$f" > "$W/$b.$O.log" 2>&1; then
            r="$r O$O=BUILD"; continue
        fi
        ( cd "$W" && limit "$TIMEOUT" "$SIM" -d "$W/$b.$O.prg" < /dev/null > "$W/$b.$O.raw" 2>/dev/null )
        rc=$?
        tr -d '\r' < "$W/$b.$O.raw" > "$W/$b.$O.got"
        if tr -d '\r' < "$exp" | cmp -s - "$W/$b.$O.got"; then r="$r O$O=PASS"
        elif [ $rc -eq 142 ]; then r="$r O$O=FAIL(timeout)"          # SIGALRM: past TIMEOUT
        elif [ $rc -gt 128 ]; then r="$r O$O=FAIL(crash: signal $((rc - 128)))"
        elif [ $rc -ne 0 ]; then r="$r O$O=FAIL(exit $rc, wrong output)"
        else r="$r O$O=FAIL(wrong output)"; fi
    done
    echo "$r"
}
export -f one limit; export XCC SIM TIMEOUT W

ls tests/fixtures/*.xc | { [ -n "$ONLY" ] && grep -- "$ONLY" || cat; } \
    | xargs -P "$JOBS" -I{} bash -c 'one "$@"' _ {} > "$W/results" 2>&1
sort -o "$W/results" "$W/results"
n=$(wc -l < "$W/results")
p0=$(grep -c 'O0=PASS' "$W/results"); p2=$(grep -c 'O2=PASS' "$W/results")
b0=$(grep -c 'O0=BUILD' "$W/results"); b2=$(grep -c 'O2=BUILD' "$W/results")
bad=$(grep -E '=FAIL' "$W/results" | awk '{print $1}')
[ -n "${KNOWN:-}" ] && bad=$(printf '%s\n' "$bad" | grep -vE "^($KNOWN)$" || true)
echo "m68k-sweep: $n fixtures; -O0 pass $p0, -O2 pass $p2; no build (the ST lacks it) $b0/$b2"
grep -E '=FAIL' "$W/results" | sed 's/^/FAIL /'
if [ -n "$bad" ]; then echo "--- m68k-sweep: FAILURES"; exit 1; fi
echo "--- m68k-sweep: OK"
