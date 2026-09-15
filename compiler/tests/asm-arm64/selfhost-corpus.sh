#!/bin/bash
# Q5 parity sweep: build every arm64-runnable corpus fixture BOTH ways — the
# clang path and `xtc --self-host` — run both, and compare. clang is the oracle
# (both at the same -O level). Reports MATCH / MISMATCH / self-host-build-fail.
# macOS/arm64 only; not part of make test (it builds + runs the whole corpus).
cd "$(dirname "$0")/../.."
XTC=bin/osx/xcc; SR=support/arm64/lib
[ -x "$XTC" ] && [ -x bin/osx/xcc-ln-arm64 ] || { echo "build first: make"; exit 1; }
match=0; mismatch=0; shfail=0; dylib=0; clangskip=0; total=0
mm=$(mktemp); bf=$(mktemp)
for f in tests/fixtures/*.xc; do
  head -20 "$f" | grep -qE 'xtc-flags:.*(skip|expect=sema-error|target=xt6502)' && continue
  total=$((total+1)); c=$(mktemp); s=$(mktemp)
  $XTC -A arm64 -L "$SR" -o "$c" "$f" >/dev/null 2>/dev/null || { clangskip=$((clangskip+1)); rm -f "$c" "$s"; continue; }
  if ! $XTC -A arm64 --self-host -L "$SR" -o "$s" "$f" >/dev/null 2>/tmp/serr.$$; then
    if grep -q 'external librar' /tmp/serr.$$; then dylib=$((dylib+1));
    else shfail=$((shfail+1)); echo "$(basename "$f"): $(tail -1 /tmp/serr.$$)" >> "$bf"; fi
    rm -f "$c" "$s"; continue
  fi
  co=$(timeout 10 "$c" 2>/dev/null); crc=$?; so=$(timeout 10 "$s" 2>/dev/null); src=$?
  # Normalise wall-clock durations (µs-level jitter is non-determinism, not a
  # codegen divergence) before comparing.
  tnorm='s/[0-9]+\.[0-9]+ secs/T secs/g'
  con=$(echo "$co" | sed -E "$tnorm"); son=$(echo "$so" | sed -E "$tnorm")
  if [ "$con" = "$son" ] && [ "$crc" = "$src" ]; then match=$((match+1));
  else mismatch=$((mismatch+1)); echo "$(basename "$f"): clang(rc=$crc) vs self(rc=$src)" >> "$mm"; fi
  rm -f "$c" "$s"
done
echo "=== self-host vs clang, arm64 corpus ($total runnable) ==="
printf 'MATCH: %d   MISMATCH: %d   build-fail: %d   ext-dylib: %d   (clang-skip: %d)\n' \
  "$match" "$mismatch" "$shfail" "$dylib" "$clangskip"
echo "--- build-fail reasons ---"; sed -E 's/^[^:]+: //' "$bf" | sort | uniq -c | sort -rn | head
echo "--- mismatches ---"; cat "$mm"
rm -f "$mm" "$bf" /tmp/serr.$$
