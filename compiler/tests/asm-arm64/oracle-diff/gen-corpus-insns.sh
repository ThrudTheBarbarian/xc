#!/bin/bash
# Emit every unique AArch64 instruction the arm64 backend produces across the
# fixture corpus, excluding local-label branches (tested at file level) and the
# not-yet-encoded FP/NEON set. Feed the output to bin/osx/oracle-arm64.
set -e
cd "$(dirname "$0")/../../.."
tmp=$(mktemp -d)
for f in tests/fixtures/*.xc; do
  bin/osx/xcc -A arm64 -S -o "$tmp/$(basename "$f" .xc).s" "$f" >/dev/null 2>&1 || true
done
cat "$tmp"/*.s \
 | grep -E '^\s+[a-z]' | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//' \
 | grep -vE '^(b|b\.[a-z]+|cbz|cbnz|tbz|tbnz)\b' \
 | grep -vE '\bL[A-Za-z0-9_$.]+$' \
 | grep -vE '^(dup|movi|ld1|st1|mcpoll)\b' \
 | grep -vE '\b[qv][0-9]+' \
 | sort -u
rm -rf "$tmp"
# NOTE: NEON (q/v registers + dup/movi/ld1/st1) and the mech pseudo `mcpoll` are
# excluded — Phase 1 does not encode NEON (that is Phase 7). Integer + scalar-FP
# (s/d registers) are all covered. The exclusion also keeps the batch strictly
# one-word-per-line so the positional byte-diff stays aligned.
