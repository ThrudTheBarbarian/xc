#!/bin/bash
# all-diff.sh — run every self-hosting differential and print ONE summary table.
# =================================================================
#
# The matrix is only "byte-identical" if every harness says so on the same day,
# against the same build. Running them one at a time and remembering the numbers
# is how a regression survives: each result is fine in isolation and nobody sees
# that one of them moved.
#
# Any harness that does not print a recognisable "pass=N fail=M" line is
# reported as BROKEN, not skipped — a harness that fails to run is exactly as
# bad as a failing comparison, and silently omitting it is what let a
# never-compared file hide a real bug (#1011, #1012).
#
# ── CONCURRENCY ──────────────────────────────────────────────────
# The harnesses run in PARALLEL (ALLDIFF_JOBS, default half the cores). They are
# independent by construction: each builds its own tool into its own
# `mktemp`/PID-scoped work directory, reads the tree read-only, and writes only
# its own log. The RESULT is therefore identical to a serial run — only the wall
# clock changes (~100 min -> a few minutes on a 16-core box).
#
# Two things this does NOT change:
#   * Do not run it against a live `make`. The tree it reads must not be
#     rebuilt underneath it, and that is about the TREE, not about CPU load.
#   * A crash is still a bug. The 2026-07-30 run had the self-hosted arm64 back
#     end SIGSEGV on selfhost/asm/U64.xc and the note here blamed "concurrency";
#     chased properly it was bug 034 — a store through `T@@` that did not
#     retain. Never write off an exit-139 as contention.
#
# `ALLDIFF_JOBS=1` restores the fully serial run.
#
#   bash selfhost/tools/all-diff.sh [-q]        # -q: table only
set -u
cd "$(dirname "$0")/../.." || exit 1
QUIET=${1:-}
LOG=${TMPDIR:-/tmp}/all-diff.$$
mkdir -p "$LOG"

CORES=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)
JOBS=${ALLDIFF_JOBS:-$(( CORES / 2 ))}
[ "$JOBS" -lt 1 ] && JOBS=1

# Stage-ordered, so a failure reads as "the pipeline broke HERE". This is the
# DISPLAY order and the order the table is printed in.
HARNESSES=(lexer pp ast sema diag ir irwide irrt iface ifacewrite opt
           arm64 arm64o3 android a9 m68k x86 wasm
           as64 as9 as68 asx86 xta xccas
           ld64 obj64 lddylib ldandroid ldarm9 ldx86 ldx86so objx86 ldwin lnwasm elfobj coffobj dwarf
           wrap65 xcc bin caps sign)

# DISPATCH order — longest first, which is what minimises the makespan when 21
# unequal jobs share N slots. A scheduling hint ONLY: it cannot change a result,
# and the table below is still printed stage-ordered.
#
# Measured 2026-08-07, 8 jobs / 16 cores (seconds):
#   x65 1374 | as64 952 | xta 827 | arm64 804 | x86 801 | ld64 665 | as68 434
#   ldwin 434 | asx86 421 | irwide 418 | a9 383 | ldx86 358 | m68k 313
#   sema 305 | ast 252 | opt 201 | irrt 108 | pp 71 | lexer 54 | ir 36 | as9 4
#   (android and ldandroid were added later — cost close to arm64 and ld64,
#    which is what they mirror under the `-A android` options.)
#
# 9215 CPU-seconds in 24.5 min wall — but the FLOOR is x65 alone at 23 min, so
# more jobs buy nothing. Breaking that needs x65 itself split across slots (its
# file loop shards cleanly) or made cheaper: the 6502 bank placer re-renders
# every function up to 8 times to reach its fixpoint, which is most of its cost.
# xcc is the DRIVER-level differential (the xc driver against the ObjC one, over
# every fixture, arm64 + android). It was written and then never dispatched, so
# it sat broken — its build line was missing `-I selfhost/link` and it could not
# compile the driver at all. A harness nothing runs is a harness nothing checks.
#
# diag is the odd one out: it compares nothing. It asserts the SHIPPED compiler
# REJECTS what it should, which every other harness here is blind to — they all
# compare dumps of input that builds. private:docs/bugs/077 lived in that blind spot:
# the shipped compiler dropped every parser and sema diagnostic, so `i32 x = ;`
# compiled to a runnable binary, silently, exit 0. Cheap (seconds), and it is
# the only thing watching the error path.
DISPATCH=(xcc bin caps wrap65 sema sign ast as64 xta xccas wasm lnwasm arm64 arm64o3 android x86 ld64 lddylib ldandroid as68 ldwin
          asx86 irwide a9 ldarm9 ldx86 ldx86so objx86 obj64 m68k dwarf opt irrt pp lexer iface ifacewrite ir as9 diag elfobj coffobj)

# HARNESSES and DISPATCH are two lists of the same set — one is the table's row
# order, the other is longest-first so the schedule packs. A name in only one of
# them is a bug in whichever direction it goes: missing from DISPATCH, the row
# is expected and nothing runs it (BROKEN); missing from HARNESSES, it runs and
# its result is never read. Both happened; this makes it impossible rather than
# noticed. (elfobj was added to HARNESSES alone and reported BROKEN — the loud
# failure was the design working, but the drift should not have been possible.)
_lists_differ=$(printf '%s\n' "${HARNESSES[@]}" | sort > /tmp/.ad_h.$$
                printf '%s\n' "${DISPATCH[@]}"  | sort > /tmp/.ad_d.$$
                comm -3 /tmp/.ad_h.$$ /tmp/.ad_d.$$
                rm -f /tmp/.ad_h.$$ /tmp/.ad_d.$$)
if [ -n "$_lists_differ" ]; then
    echo "all-diff: HARNESSES and DISPATCH disagree — these appear in only one:" >&2
    echo "$_lists_differ" | sed 's/^/  /' >&2
    exit 2
fi

# How many SLOTS each harness is split across. The makespan was bounded by the
# single longest harness — x65 alone ran 23 of the 24.5 minutes, so the other
# 25 finished in its shadow and more jobs bought nothing. A harness's file loop
# shards cleanly (SHARD_I/SHARD_N in each script), so the long ones are cut into
# pieces that schedule independently and the floor drops with them.
#
# Only the long ones: a shard costs one process start and one tool build, which
# is pure loss on a harness that already finishes in a minute.
# x65 is NOT in the default matrix. wrap65 SUBSUMES it: x65 strips the runtime
# wrap off the oracle and compares the back end's share of the text, wrap65
# compares the whole thing, so a byte-identical wrap65 means the back end
# agreed too. Running both costs ~3300 CPU-seconds a gate — 10% of the matrix —
# to learn nothing extra. It is still there for DIAGNOSIS: when wrap65 goes red,
# `bash selfhost/tools/x65-diff.sh` says whether the divergence is the back end
# or the wrap, which is the one question wrap65 alone cannot answer.
shards_for() {
    # Shard counts are RIGHT-SIZED, not maximised. Measured 2026-08-28: the
    # matrix is ~29,000 CPU-seconds and packs at ~90% efficiency on 14 jobs, so
    # it is CPU-BOUND, not floor-bound — and every extra shard REBUILDS that
    # harness's port tool, which costs ~38s. Going wide on a harness that is
    # already well under the CPU/jobs floor (~2000s) buys nothing and pays a
    # build for it; ~70 shards where 31 suffice wastes ~1500 CPU-seconds a gate.
    #
    # So: shard only what exceeds the floor, by ceil(total / floor).
    #   xcc    4621s -> 4     wrap65 3447s -> 3     everything else <2000s -> 1
    #
    # MEASURED, not predicted: cutting xcc to 3 and wrap65 to 2 saved 1.3 min,
    # not the 5 estimated — the build overhead was smaller than guessed and the
    # thinner sharding RAISED the tail, leaving wrap65's single 1739s shard as
    # a 29-minute floor by itself. Both effects are real and they pull opposite
    # ways: shard the few harnesses above the floor enough to get under it, and
    # leave everything else alone.
    #
    # Re-derive after a coverage change with the per-harness totals:
    #   for h in $LOG/*.time; do ...; done   (all-diff prints $LOG on failure)
    case "$1" in
        xcc)                 echo 4 ;;
        bin)                 echo 6 ;;   # five targets, two in-house links a fixture: ~2.7 h unsharded (measured 2026-09-04)
        wrap65)              echo 3 ;;
        caps)                echo 2 ;;   # 19 flag sets over one fixture in sixteen
        x65)                 echo 3 ;;   # not dispatched; for a manual run
        *)                   echo 1 ;;
    esac
}

DISPATCH_SHARDED=()
for _h in "${DISPATCH[@]}"; do
    _n=$(shards_for "$_h")
    if [ "$_n" = 1 ]; then DISPATCH_SHARDED+=("$_h")
    else _i=0; while [ "$_i" -lt "$_n" ]; do DISPATCH_SHARDED+=("$_h:$_i:$_n"); _i=$((_i+1)); done
    fi
done

echo "all-diff: $JOBS jobs on $CORES cores" >&2

# Each harness records its own wall time, so the table can show where the time
# goes — one that doubles in cost is worth noticing before it becomes the reason
# nobody runs this.
#
# xargs -P, not `wait -n`: macOS ships bash 3.2, which has no `wait -n`. The
# body is inline rather than an exported function for the same reason — bash 3.2
# exports functions through the environment, which is exactly the mechanism
# Shellshock came through and is disabled in some builds.
# xargs runs in the BACKGROUND and is waited on, so this script can be killed
# and still clean up. A trap does not fire while a foreground pipeline runs —
# bash defers it until the command returns — so with xargs in the foreground the
# harnesses simply outlived their parent: a stopped run left every one of them
# behind, competing with the NEXT run and making its numbers look like a
# regression. `wait` is interruptible, which is what makes the trap reachable.
printf '%s\n' "${DISPATCH_SHARDED[@]}" \
  | xargs -P "$JOBS" -I{} bash -c 'cd "$0"; LOG="$1"; spec="$2"
        h=${spec%%:*}
        rest=${spec#"$h"}
        if [ -n "$rest" ]; then rest=${rest#:}; si=${rest%%:*}; sn=${rest#*:}
        else si=0; sn=1; fi
        s="selfhost/tools/$h-diff.sh"
        if [ ! -f "$s" ]; then echo "NO HARNESS" > "$LOG/$h.missing"; exit 0; fi
        st=$(date +%s)
        SHARD_I=$si SHARD_N=$sn bash "$s" > "$LOG/$h.$si.txt" 2>&1
        echo $(( $(date +%s) - st )) > "$LOG/$h.$si.time"' "$PWD" "$LOG" {} &
XARGS_PID=$!
# Kill a process and everything below it, deepest first. Only THIS run's tree:
# the cleanup used to finish with a system-wide `pkill -f '*-diff.sh'`, and it
# is trapped on EXIT, so every all-diff that finished normally also killed any
# other all-diff running on the machine, from another checkout or worktree.
killtree() {
    local c
    for c in $(pgrep -P "$1" 2>/dev/null); do killtree "$c"; done
    kill "$1" 2>/dev/null
}
cleanup() {
    trap - EXIT INT TERM
    # The harnesses are grandchildren (xargs -> bash -c -> *-diff.sh) and
    # start compilers of their own, so reap the whole tree.
    killtree "$XARGS_PID"
}
trap cleanup EXIT INT TERM
wait "$XARGS_PID"
trap - EXIT INT TERM

printf '%-10s %8s %6s %8s %6s  %s\n' STAGE PASS FAIL SKIPPED TIME VERDICT
printf '%-10s %8s %6s %8s %6s  %s\n' ---------- -------- ------ -------- ------ -------
totalfail=0; broken=0
for h in "${HARNESSES[@]}"; do
    # A harness's shards are summed back into one row: pass/fail/skipped add,
    # and the TIME shown is the slowest shard, because that is what the run
    # actually waited for.
    t=$(cat "$LOG/$h".*.time 2>/dev/null | sort -n | tail -1)
    t=$( [ -n "$t" ] && printf '%ss' "$t" || echo - )
    cat "$LOG/$h".*.txt > "$LOG/$h.txt" 2>/dev/null
    if [ -f "$LOG/$h.missing" ]; then
        printf '%-10s %8s %6s %8s %6s  %s\n' "$h" - - - "$t" "NO HARNESS"
        broken=$((broken+1)); continue
    fi
    # EVERY shard must have reported. A shard that produced no summary is a
    # harness that did not run, and summing the rest would hide it behind its
    # siblings' passes — the one failure mode sharding could introduce.
    nshards=$(shards_for "$h")
    got=$(grep -lE 'pass=[0-9]+ fail=[0-9]+' "$LOG/$h".*.txt 2>/dev/null | wc -l | tr -d ' ')
    if [ "$got" != "$nshards" ]; then
        printf '%-10s %8s %6s %8s %6s  %s\n' "$h" - - - "$t" \
            "BROKEN ($got/$nshards shards reported; see $LOG/$h.*.txt)"
        broken=$((broken+1)); continue
    fi
    p=$(grep -hoE 'pass=[0-9]+' "$LOG/$h".*.txt | awk -F= '{t+=$2} END{print t+0}')
    f=$(grep -hoE 'fail=[0-9]+' "$LOG/$h".*.txt | awk -F= '{t+=$2} END{print t+0}')
    sk=$(grep -hoE '(oracle-failed|unsupported)=[0-9]+' "$LOG/$h".*.txt \
         | awk -F= '{t+=$2} END{print t+0}')
    # A harness that COMPARED NOTHING is not green. a9 sat at pass=0 fail=0 with
    # 853 skipped for as long as its sysroot default was stale, and printed ok
    # every time: fail=0 was the only thing this looked at. Zero comparisons is
    # a broken harness, exactly like a shard that failed to report.
    v="ok"
    if [ "$p" = 0 ] && [ "$f" = 0 ]; then
        v="BROKEN (0 compared)"; broken=$((broken+1))
    elif [ "$f" != 0 ]; then
        v="FAIL"; totalfail=$((totalfail+f))
    fi
    printf '%-10s %8s %6s %8s %6s  %s\n' "$h" "$p" "$f" "$sk" "$t" "$v"
    [ "$f" != 0 ] && [ "$QUIET" != "-q" ] && grep -A 6 'differing\|closest failures' "$LOG/$h.txt" | head -7
done
echo
if [ "$totalfail" = 0 ] && [ "$broken" = 0 ]; then
    echo "ALL HARNESSES BYTE-IDENTICAL"
    echo "SKIPPED is files the ORACLE could not build — not compared, and NOT passes."
    exit 0
fi
echo "failures=$totalfail broken-harnesses=$broken   logs: $LOG"
echo "SKIPPED is files the ORACLE could not build — not compared, and NOT passes."
# EXIT NON-ZERO. This printed a table and exited 0 whatever was in it, which is
# fine for a human reading the table and useless to anything that isn't: CI
# checks status, not stdout. A run that reported `broken-harnesses=1` — x65
# failing to build its tool — exited 0 and would have been a green build.
exit 1
