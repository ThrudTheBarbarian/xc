#!/bin/bash
# o3-nightly.sh — run the -O3 differentials and leave a triage list behind.
# =========================================================================
#
# The -O3 harnesses (task #48) compare every ported back end on the IR level
# everything actually ships at. Running the whole matrix takes hours, so this is
# NOT part of `make test`, `all-diff`, or any check-in gate (task #49) — it is
# an overnight job whose output is a morning to-do list.
#
#   bash selfhost/tools/o3-nightly.sh [outdir]
#
# What it leaves behind, under <outdir> (default logs/o3-<date>):
#   <harness>.log     the harness's full output
#   SUMMARY.txt       one line per harness, and the first divergences of each
#
# Design notes worth keeping:
#
#   * It runs the harnesses SEQUENTIALLY. They each build a port tool, and a
#     concurrent build is what produced a one-off SIGSEGV in a self-hosted back
#     end before; an overnight job has the time to be careful.
#   * A harness that FAILS TO RUN is reported as BROKEN, distinct from one that
#     ran and found divergences. Collapsing the two is how a harness sits dead
#     for a month while its row reads clean.
#   * A harness that compared NOTHING is also BROKEN. pass=0 fail=0 is not
#     green — it is a harness whose oracle could not build anything.
#   * The exit status is 0 even when there are divergences. This job's PURPOSE
#     is to find them; failing the run would tempt someone to wire it into CI,
#     which is exactly what task #49 says not to do. BROKEN is a non-zero exit,
#     because that means the measurement did not happen.
set -u
cd "$(dirname "$0")/../.." || exit 1

STAMP=$(date +%Y-%m-%d)
OUT=${1:-logs/o3-$STAMP}
mkdir -p "$OUT" || exit 1

HARNESSES="arm64o3 m68ko3 x86o3 a9o3 wasmo3"

SUM="$OUT/SUMMARY.txt"
: > "$SUM"
{
    echo "-O3 differential sweep — $(date '+%Y-%m-%d %H:%M')"
    echo "$(uname -srm)"
    echo "commit $(git rev-parse --short HEAD 2>/dev/null || echo '?')"
    echo
} >> "$SUM"

broken=0
started=$(date +%s)
for h in $HARNESSES; do
    s="selfhost/tools/$h-diff.sh"
    if [ ! -f "$s" ]; then
        printf '%-10s %s\n' "$h" "NO HARNESS" >> "$SUM"; broken=$((broken+1)); continue
    fi
    t0=$(date +%s)
    echo "=== $h — started $(date +%H:%M) ==="
    bash "$s" > "$OUT/$h.log" 2>&1
    rc=$?
    t=$(( $(date +%s) - t0 ))

    line=$(grep -oE 'pass=[0-9]+ fail=[0-9]+( unsupported=[0-9]+)?( oracle-failed=[0-9]+)?' \
           "$OUT/$h.log" | tail -1)
    if [ -z "$line" ]; then
        printf '%-10s %6ss  BROKEN (no summary line; see %s)\n' "$h" "$t" "$OUT/$h.log" >> "$SUM"
        broken=$((broken+1)); continue
    fi
    p=$(echo "$line" | grep -oE 'pass=[0-9]+' | cut -d= -f2)
    f=$(echo "$line" | grep -oE 'fail=[0-9]+' | cut -d= -f2)
    if [ "$p" = 0 ] && [ "$f" = 0 ]; then
        printf '%-10s %6ss  BROKEN (0 compared — the oracle built nothing)\n' "$h" "$t" >> "$SUM"
        broken=$((broken+1)); continue
    fi
    verdict=ok
    [ "$f" != 0 ] && verdict="$f DIVERGE"
    printf '%-10s %6ss  %s  (%s)\n' "$h" "$t" "$verdict" "$line" >> "$SUM"
    if [ "$f" != 0 ]; then
        {
            echo
            echo "  --- $h, first divergences ---"
            sed -n '/--- differing/,/^--- /p' "$OUT/$h.log" | head -16 | sed 's/^/  /'
        } >> "$SUM"
    fi
done

{
    echo
    echo "total $(( ($(date +%s) - started) / 60 )) min"
    if [ "$broken" != 0 ]; then
        echo "$broken harness(es) did NOT run — that is a broken measurement, not a clean sweep."
    fi
    echo
    echo "These are a BACKLOG (task #49), not a gate. File the interesting ones as"
    echo "docs/bugs/NNN-*.md and work them down; do not wire this into check-in."
} >> "$SUM"

cat "$SUM"
[ "$broken" -eq 0 ]
