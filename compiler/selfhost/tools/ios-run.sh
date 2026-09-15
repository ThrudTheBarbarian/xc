#!/bin/bash
# ios-run.sh — the SHIPPED compiler's ios-sim binaries, run in the simulator.
#
#   bash selfhost/tools/ios-run.sh [pattern]
#
# bin-diff says the two drivers agree byte for byte; this says the bytes DO
# the right thing on the platform. Every fixture with an expected output that
# builds for ios-sim is linked in-house by xcc-xc, spawned on a booted iPhone
# simulator with `xcrun simctl spawn`, and its stdout diffed against the
# fixture's .expected.out — the iOS twin of what the corpus does natively and
# what wine does for win64 (docs/mobile/iOS.md, Stage 0's gate).
#
# Skips CLEANLY (exit 0, and says so) with no xcrun or no booted simulator:
# a CI host without Xcode has not checked anything, and the line says that.
set -u
cd "$(dirname "$0")/../.." || exit 1
BIN=bin/osx
PATTERN=${1:-}
XCC=${XCC:-$BIN/xcc-xc}
[ -x "$XCC" ] || { echo "ios-run: no $XCC (make production)"; exit 1; }
command -v xcrun >/dev/null 2>&1 || { echo "--- ios-run: SKIPPED (no xcrun) ---"; exit 0; }
UDID=$(xcrun simctl list devices 2>/dev/null | grep -m1 'iPhone.*(Booted)' | grep -oE '[0-9A-F-]{36}')
[ -n "$UDID" ] || { echo "--- ios-run: SKIPPED (no booted iPhone simulator; xcrun simctl boot one) ---"; exit 0; }
WORK=${TMPDIR:-/tmp}/iosrun.$$
mkdir -p "$WORK"; trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0; nobuild=0
declare -a FAILED
# The platform LAYER (iOS.md stage 4): support/ios/lib's prelude must be the
# one both drivers find, agree on byte for byte, and answer "ios-sim" from.
printf '#use Stdio\ni32 main(void) { printf("%%s\\n", Ios.platform().cString()); return 0; }\n' > "$WORK/iosplat.xc"
mkdir -p "$WORK/a" "$WORK/b"
# Url.fetch through the platform's NSURLSession transport (stage 4): a
# file:// fetch of a known file, both drivers, byte-identical, right body.
printf 'fetched by NSURLSession\n' > "$WORK/fx.txt"
printf '#use Stdio\ni32 main(void) { Url* u = Url.withString(String.withCString("file://%s/fx.txt")); u.fetch(block void(u32 status, String* body) { printf("%%lu %%s", status, body == 0 ? "" : body.cString()); }); return 0; }\n' "$WORK" > "$WORK/iosfetch.xc"
if "$BIN/xcc" -q -A ios-sim -H . -o "$WORK/a/iosfetch" "$WORK/iosfetch.xc" >/dev/null 2>&1 \
   && "$XCC" -q -A ios-sim -H . -o "$WORK/b/iosfetch" "$WORK/iosfetch.xc" >/dev/null 2>&1 \
   && cmp -s "$WORK/a/iosfetch" "$WORK/b/iosfetch" \
   && [ "$(xcrun simctl spawn "$UDID" "$WORK/b/iosfetch" 2>/dev/null)" = "200 fetched by NSURLSession" ]; then
    pass=$((pass+1))
else
    fail=$((fail+1)); FAILED+=("ios-nsurlsession-fetch (build, agreement or answer)")
fi
if "$BIN/xcc" -q -A ios-sim -H . -o "$WORK/a/iosplat" "$WORK/iosplat.xc" >/dev/null 2>&1 \
   && "$XCC" -q -A ios-sim -H . -o "$WORK/b/iosplat" "$WORK/iosplat.xc" >/dev/null 2>&1 \
   && cmp -s "$WORK/a/iosplat" "$WORK/b/iosplat" \
   && [ "$(xcrun simctl spawn "$UDID" "$WORK/b/iosplat" 2>/dev/null)" = "ios-sim" ]; then
    pass=$((pass+1))
else
    fail=$((fail+1)); FAILED+=("ios-platform-layer (support/ios/lib prelude: build, agreement or answer)")
fi
for f in $(ls tests/fixtures/*.xc | sort); do
    [ -n "$PATTERN" ] && [[ "$f" != *"$PATTERN"* ]] && continue
    b=$(basename "$f" .xc)
    exp="tests/fixtures/$b.expected.out"
    [ -f "$exp" ] || continue
    # The corpus directives that exclude a host run: another target, a
    # deliberate skip, a fixture that must FAIL to compile, or one that needs
    # flags/args/stdin the plain build does not give.
    dir=$(grep -h '^//xtc-' "$f" 2>/dev/null | tr '\n' ' ')
    case "$dir" in
        *skip*|*expect=*|*target=xt6502*|*target=m68k*|*target=wasm32*|*target=arm9*|*target=x86_64*|*target=win64*|*target=android*|*args*|*stdin*|*flags*|*link:*) continue;;
    esac
    # `//xtc-na: arm64,…` — the fixture asserts something only another target
    # has (a 6502 zero-page sentinel, 5-byte-float digits). ios-sim IS the
    # arm64 back end, so arm64's not-applicable list is its own.
    na=$(grep -h '^//xtc-na:' "$f" 2>/dev/null | head -1)
    case "$na" in *arm64*|*ios*) continue;; esac
    rm -f "$WORK/a.bin"
    if ! "$XCC" -A ios-sim -H . -q -o "$WORK/a.bin" "$f" >/dev/null 2>&1 || [ ! -s "$WORK/a.bin" ]; then
        nobuild=$((nobuild+1)); continue
    fi
    xcrun simctl spawn "$UDID" "$WORK/a.bin" > "$WORK/out" 2>/dev/null
    if cmp -s "$WORK/out" "$exp"; then pass=$((pass+1))
    else fail=$((fail+1)); FAILED+=("$b"); fi
done
echo "--- ios-run: pass=$pass fail=$fail not-built=$nobuild ---"
if [ "$fail" -gt 0 ]; then echo "--- wrong output (first 20):"; printf '  %s\n' "${FAILED[@]}" | head -20; fi
echo "not-built are fixtures xcc-xc could not link for ios-sim: not run, and NOT passes."
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
