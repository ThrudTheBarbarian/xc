#!/bin/bash
# xc-x86_64-run.sh — the SHIPPED compiler's x86-64 target, end to end.
# =====================================================================
#
# Compiles every corpus fixture with `xcc-xc -A x86_64`, runs the result on a
# real x86-64 Linux host, and diffs against the fixture's expected output. This
# is the only thing that answers "does -A x86_64 work" — a target that builds
# an ELF nobody executes is not a working target (task #41/#47).
#
#   bash selfhost/tools/xc-x86_64-run.sh [pattern]
#
# The host is $XTC_LINUX_HOST (set in build.env), reached over ssh. Binaries
# are built locally, copied ONCE as a batch, and run in one remote session —
# per-fixture ssh would dominate the runtime and tell us nothing extra.
#
# A fixture with no .expected.out is NOT a pass: it is counted separately, the
# way the corpus counts a hollow oracle, because "it ran and printed something"
# is not a check.
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
set -u
cd "$(dirname "$0")/../.." || exit 1

BIN=bin/osx
[ -x "$BIN/xcc-xc" ] || BIN=bin/linux
HOST=${XTC_LINUX_HOST:-}
PATTERN=${1:-}
# Build the compiler under test FIRST. `make` alone does not relink xcc-xc — it
# is its own target — so an edit to selfhost/ leaves a stale binary here that
# runs happily and produces yesterday's code. That is not hypothetical: a stale
# xcc-xc emitting the OLD 2-byte ARC sequence against a freshly widened 40-byte
# object header turned this sweep from 383/0 into 309/74, and every failure
# looked like a miscompile in the change under test.
make -s production >/dev/null 2>&1 || true

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

if ! ssh -o ConnectTimeout=8 -o BatchMode=yes "$HOST" true 2>/dev/null; then
    echo "--- xc-x86_64-run: SKIPPED (no ssh to $HOST) ---"
    exit 0
fi

built=0; buildfail=0; noexp=0; skipped=0; multi=0
declare -a BUILDFAIL
for f in tests/fixtures/*.xc; do
    b=$(basename "$f" .xc)
    [ -n "$PATTERN" ] && [[ "$b" != *"$PATTERN"* ]] && continue
    # Respect the fixture's own directives. Getting this wrong does not fail
    # safe: int_arith.xc carries 6502 inline asm and is marked
    # `//xtc-na: ...,x86_64,...`, and compiling it anyway fed LDA/STA to the
    # x86 assembler — a "failure" that says nothing about the target.
    #
    #   //xtc-na: <list>          not applicable on these targets
    #   //xtc-flags: target=<t>   this fixture is for one backend only
    #   skip                      not run at all
    hdr=$(head -30 "$f")
    printf '%s' "$hdr" | grep -q '^//xtc-.*skip' && { skipped=$((skipped+1)); continue; }
    # A //xtc-link: fixture is TWO compilation units merged into one. The xc
    # driver still refuses multiple .xc inputs, so these cannot be built by it
    # at all — counted apart, because calling them x86-64 failures would blame
    # the wrong thing entirely.
    if printf '%s' "$hdr" | grep -q '^//xtc-link:'; then
        multi=$((multi+1)); continue
    fi
    na=$(printf '%s' "$hdr" | sed -n 's|^//xtc-na: *||p' | head -1)
    case ",$(printf '%s' "$na" | tr -d ' ')," in
        *,x86_64,*) skipped=$((skipped+1)); continue ;;
    esac
    tgt=$(printf '%s' "$hdr" | sed -n 's|.*target=\([A-Za-z0-9_]*\).*|\1|p' | head -1)
    if [ -n "$tgt" ] && [ "$tgt" != both ]; then
        skipped=$((skipped+1)); continue
    fi
    if [ ! -f "tests/fixtures/$b.expected.out" ]; then noexp=$((noexp+1)); continue; fi
    if "$BIN/xcc-xc" -A x86_64 -H . -o "$WORK/bin/$b" "$f" >"$WORK/$b.log" 2>&1; then
        built=$((built+1))
    else
        buildfail=$((buildfail+1))
        BUILDFAIL+=("$b: $(grep -m1 -o 'error:.*' "$WORK/$b.log" | cut -c1-90)")
    fi
done

if [ "$built" = 0 ]; then
    # Nothing to run. That is only a FAILURE if something failed to build —
    # a selection where every fixture was skipped is a legitimate empty run,
    # and reporting it as a failure trains the reader to ignore the result.
    if [ "$buildfail" = 0 ]; then
        echo "--- xc-x86_64-run: pass=0 fail=0 skipped=$skipped no-expected=$noexp multi-unit=$multi (nothing applicable) ---"
        exit 0
    fi
    echo "--- xc-x86_64-run: pass=0 fail=$buildfail --- (nothing built; see below)"
    printf '  %s\n' "${BUILDFAIL[@]:0:15}"
    exit 1
fi

RDIR=/tmp/xcx86-$$
ssh "$HOST" "rm -rf $RDIR && mkdir -p $RDIR" 2>/dev/null
scp -q -r "$WORK/bin/." "$HOST:$RDIR/" 2>/dev/null
ssh "$HOST" "cd $RDIR && chmod +x * 2>/dev/null; for x in *; do echo \"===FIXTURE:\$x\"; timeout 10 ./\$x 2>&1; echo \"===RC:\$?\"; done" > "$WORK/out.txt" 2>/dev/null
ssh "$HOST" "rm -rf $RDIR" 2>/dev/null

pass=0; fail=0
declare -a FAILED
cur=""; : > "$WORK/cur.txt"
finish() {
    [ -z "$cur" ] && return
    if diff -q "tests/fixtures/$cur.expected.out" "$WORK/cur.txt" >/dev/null 2>&1; then
        pass=$((pass+1))
    else
        fail=$((fail+1))
        FAILED+=("$cur ($(diff "tests/fixtures/$cur.expected.out" "$WORK/cur.txt" 2>/dev/null | grep -c '^[<>]') lines)")
    fi
}
while IFS= read -r line; do
    case "$line" in
        ===FIXTURE:*) finish; cur=${line#===FIXTURE:}; : > "$WORK/cur.txt" ;;
        ===RC:*)      ;;
        *)            printf '%s\n' "$line" >> "$WORK/cur.txt" ;;
    esac
done < "$WORK/out.txt"
finish

if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "--- differing (first 20):"
    printf '  %s\n' "${FAILED[@]}" | head -20
fi
if [ "${#BUILDFAIL[@]}" -gt 0 ]; then
    echo "--- would not BUILD (first 15):"
    printf '  %s\n' "${BUILDFAIL[@]}" | head -15
fi
echo "--- xc-x86_64-run: pass=$pass fail=$fail build-failed=$buildfail no-expected=$noexp skipped=$skipped multi-unit=$multi ---"
[ "$fail" = 0 ] && [ "$buildfail" = 0 ]
