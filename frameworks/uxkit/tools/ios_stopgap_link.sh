#!/bin/sh
# ios_stopgap_link.sh — link an ios-sim binary with the platform clang, as the
# STOPGAP while bug 028 (the in-house linker's bind-ordinal defect) is open.
# The moment 028 lands this file's callers switch to one `xcc -A ios-sim` line
# and this script retires — that is its whole ambition.
#
# The xtc runtime is the compiler-under-test's rt-macos.s, which is two
# concatenated emissions (see 028's notes): split at the .build_version seams,
# stamps stripped so -target governs, cached beside the outputs.
#
# usage: ios_stopgap_link.sh <out> <obj...> [-framework F ...]
set -e
OUT="$1"; shift
# The runtime comes from the compiler UNDER TEST — $XCC, or the xcc on PATH —
# resolved through symlinks and accepting both layouts (an install's lib/xc,
# a source tree's support/). It used to come from whatever `xcc` was on PATH
# and, when there was none, from a cache keyed on that missing file's mtime:
# the cached objects were from 26 Aug, the hosted refcount went 32-bit on
# 31 Aug, and every compiler after that was linked against a 16-bit-refcount
# runtime — "boot ok" then silence (compiler bug 122, which was this script).
# The cache is keyed on the runtime's CONTENT now, so a changed runtime can
# never be served stale and two toolchains never share one cache.
XCC_BIN="${XCC:-$(command -v xcc || true)}"
[ -n "$XCC_BIN" ] || { echo "ios_stopgap_link: no xcc on PATH and \$XCC unset" >&2; exit 1; }
while [ -L "$XCC_BIN" ]; do
  l=$(readlink "$XCC_BIN"); case "$l" in /*) XCC_BIN="$l";; *) XCC_BIN="$(dirname "$XCC_BIN")/$l";; esac
done
BINDIR=$(cd "$(dirname "$XCC_BIN")" && pwd)
RT=""
for home in "$BINDIR/.." "$BINDIR/../.."; do
  for rel in lib/xc xc support; do
    [ -f "$home/$rel/arm64/runtime/rt-macos.s" ] && { RT="$home/$rel/arm64/runtime/rt-macos.s"; break 2; }
  done
done
[ -n "$RT" ] || { echo "ios_stopgap_link: no arm64/runtime/rt-macos.s beside '$XCC_BIN'" >&2; exit 1; }
TGT="arm64-apple-ios15.0-simulator"
KEY=$(shasum -a 256 "$RT" | cut -c1-16)
CACHE="${TMPDIR:-/tmp}/uxkit-ios-rt/$KEY"
mkdir -p "$CACHE"
# 0.4's runtime was two concatenated emissions (a second .build_version in
# the middle) and had to be split; 0.5's is one. Split at the seam when there
# is one, else assemble the file whole.
if [ ! -f "$CACHE/done" ]; then
  seam=$(grep -n ".build_version" "$RT" | sed -n '2p' | cut -d: -f1)
  if [ -n "$seam" ]; then
    sed -n "1,$((seam-1))p" "$RT"  | sed '/\.build_version/d' > "$CACHE/rtA.s"
    sed -n "${seam},\$p" "$RT"     | sed '/\.build_version/d' > "$CACHE/rtB.s"
  else
    sed '/\.build_version/d' "$RT" > "$CACHE/rtA.s"
  fi
  for part in rtA rtB; do
    [ -f "$CACHE/$part.s" ] && xcrun -sdk iphonesimulator clang -target "$TGT" -c "$CACHE/$part.s" -o "$CACHE/$part.o"
  done
  touch "$CACHE/done"
fi
RTOBJS="$CACHE/rtA.o"; [ -f "$CACHE/rtB.o" ] && RTOBJS="$RTOBJS $CACHE/rtB.o"
xcrun -sdk iphonesimulator clang -target "$TGT" "$@" $RTOBJS -o "$OUT"
