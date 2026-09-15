#!/bin/sh
# selfhost-corpus.sh — a light standalone harness for iterating on the
# SELF-HOSTED Linux path: xtc -> XAX86_64Assembler -> XTElfWriter, with no clang,
# no ld.lld and no musl anywhere.
#
# For the AUTHORITATIVE number use `make selfhost-x86_64-corpus`, which runs the
# real sweep with XTC_X86_SELFHOST=1. This script applies its own fixture filter
# and skips //xtc-link: companions, so its count is NOT comparable with
# `make corpus` — it is a fast signal, not a measurement.
#
# Everything is built on the Mac, shipped to a Linux host in one tarball, and run
# there in one ssh — per-fixture scp would dominate the runtime.
#
#   ./tests/asm-x86_64/selfhost-corpus.sh [fixture-glob]
#
# The Linux host is XTC_LINUX_HOST (set in build.env).
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
set -e
cd "$(dirname "$0")/../.."

HOST="${XTC_LINUX_HOST:-}"
GLOB="${1:-*}"
WORK="${XTC_WORK_DIR:-/tmp}/selfhost-corpus"

[ -x bin/osx/xcc-ln-x86_64 ] || { echo "build first: make"; exit 1; }
ssh -o BatchMode=yes -o ConnectTimeout=5 "$HOST" true 2>/dev/null || {
    echo "selfhost-corpus: SKIP (no Linux host '$HOST')"; exit 0; }

rm -rf "$WORK"; mkdir -p "$WORK/bin"
compiled=0 asmfail=0 linkfail=0 companion=0 fellback=0

for f in tests/fixtures/$GLOB.xc; do
    [ -f "$f" ] || continue
    b=$(basename "$f" .xc)
    # Fixtures the corpus itself skips, or that target another architecture.
    # Directives live on `//xtc-flags:` lines: `skip`, `target=<arch>`.
    grep -E '^//xtc-flags:' "$f" 2>/dev/null | grep -qE '(^|[ ,:])skip([ ,]|$)' && continue
    grep -E '^//xtc-flags:' "$f" 2>/dev/null |
        grep -qE 'target=(xt6502|m68k|arm9|atarist|arm64|win64)' && continue
    # //xtc-na: lists architectures a fixture does not apply to (6502 inline asm,
    # zero-page sentinels &c). `make corpus` honours it; so must we.
    grep -E '^//xtc-na:' "$f" 2>/dev/null | grep -q 'x86_64' && continue
    # //xtc-link: fixtures need the caller's prototypes stripped and the
    # companion merged as one unit — XTCorpusSweep does that in Objective-C and
    # this script does not. Count them rather than dropping them silently: what
    # they exercise is the front end, and the self-hosted path differs only at
    # the link stage.
    if grep -q '^//xtc-link:' "$f" 2>/dev/null; then
        companion=$((companion+1)); continue
    fi
    [ -f "tests/fixtures/$b.expected.out" ] || continue

    # One invocation: --self-host drives xcc-cg-x86_64 then xcc-ln-x86_64, adds the
    # runtime and the per-class allocators, and never touches clang.
    #
    # NOT -q, and the stderr is checked: --self-host FALLS BACK to clang if the
    # in-house link fails. That is right for a user, but here it would let a
    # clang-built binary be counted as a self-hosted pass — the number would be
    # measuring the wrong toolchain. A fallback is a failure for this script.
    if ! ./bin/osx/xcc -A x86_64 --self-host "$f" -o "$WORK/bin/$b" \
             2>"$WORK/$b.err"; then
        cat "$WORK/$b.err" >> "$WORK/link-errors.txt"
        linkfail=$((linkfail+1)); echo "$b" >> "$WORK/link-fail.txt"; continue
    fi
    if grep -q "retrying with clang" "$WORK/$b.err"; then
        cat "$WORK/$b.err" >> "$WORK/link-errors.txt"
        fellback=$((fellback+1)); echo "$b" >> "$WORK/fellback.txt"
        rm -f "$WORK/bin/$b"; continue
    fi
    cp "tests/fixtures/$b.expected.out" "$WORK/bin/$b.expected"
    compiled=$((compiled+1))
done

rm -f "$WORK"/*.err
echo "compiled+linked $compiled   (compile fail $asmfail, link fail $linkfail, //xtc-link: not attempted $companion, fell back to clang $fellback)"
[ "$compiled" -gt 0 ] || exit 0

tar -czf "$WORK/payload.tgz" -C "$WORK/bin" .
scp -q "$WORK/payload.tgz" "$HOST:/tmp/xtc-selfhost.tgz"
ssh "$HOST" 'rm -rf /tmp/xtc-selfhost && mkdir -p /tmp/xtc-selfhost &&
  tar -xzf /tmp/xtc-selfhost.tgz -C /tmp/xtc-selfhost && cd /tmp/xtc-selfhost &&
  pass=0; fail=0; crash=0
  for b in *; do
    case "$b" in *.expected) continue;; esac
    chmod +x "$b"
    got=$(timeout 10 ./"$b" 2>/dev/null); st=$?
    if [ $st -ge 128 ] || [ $st = 124 ]; then crash=$((crash+1)); echo "CRASH($st) $b"
    elif [ "$got" = "$(cat "$b.expected")" ]; then pass=$((pass+1))
    else fail=$((fail+1)); echo "DIFF $b"; fi
  done
  echo "--- self-hosted linux: $pass pass, $fail diff, $crash crash"'

echo "link errors by cause:"
sed 's/.*undefined symbol/undefined symbol/' "$WORK/link-errors.txt" 2>/dev/null |
    sed "s/'.*'/'X'/;s/undefined symbol 'X'.*/undefined symbol/" | sort | uniq -c | sort -rn | head
grep -oE "undefined symbol '[^']*'" "$WORK/link-errors.txt" 2>/dev/null |
    sort | uniq -c | sort -rn | head -20
