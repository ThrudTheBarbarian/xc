#!/bin/bash
# lib-runtime-objlink.sh — an xc library that takes libRuntime loads into a
# program linked from objects (#620). Such a program keeps the runtime its own
# and names no run path to libRuntime, so the library carries one: its link
# writes libRuntime's directory after @loader_path / $ORIGIN, as a program's
# does. Also a program built from two sources, which links that way too.
# Skipped where the host target has no libRuntime built.
#
#   bash tests/driver/lib-runtime-objlink.sh
set -u
export XC_PAR_REMOTE=none
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) ROW=arm64-macos; EXT=dylib; A=arm64 ;;
    Linux-x86_64) ROW=x86_64-linux; EXT=so; A=x86_64 ;;
    Linux-aarch64) ROW=arm64-linux; EXT=so; A=arm64-linux ;;
    *) echo "--- lib-runtime-objlink: skipped (host) ---"; exit 0 ;;
esac
[ -f "support/runtime-lib/$ROW/libRuntime.$EXT" ] || { echo "--- lib-runtime-objlink: skipped (no libRuntime for $ROW) ---"; exit 0; }
H=$PWD
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0
bad() { echo "  FAIL: $*"; fail=1; }
cat > "$W/nBits.xc" <<'EOF'
class NBits { static u16 twice(u16 v) { return v * (u16)2; } }
EOF
cat > "$W/nMod.xc" <<'EOF'
#import <nBits>
u16 nDouble(u16 v) { return NBits.twice(v); }
EOF
cat > "$W/nMain.xc" <<'EOF'
#import "Stdio.xc"
u16 nDouble(u16 v);
i32 main(void) { Stdio.printf("%d\n", nDouble((u16)21)); return 0; }
EOF
cd "$W" || exit 1
"$H/$XC" -q -A $A -H "$H" --emit-lib nBits.xc -o libnBits.$EXT > b.log 2>&1 \
    || { echo "FAIL lib-runtime-objlink: the library does not build"; head -5 b.log; exit 1; }
# The library takes libRuntime: otherwise there is nothing to test.
grep -q "libRuntime\.$EXT" libnBits.$EXT || { echo "--- lib-runtime-objlink: skipped (the library does not take libRuntime) ---"; exit 0; }
if "$H/$XC" -q -A $A -H "$H" -L . -c nMod.xc -o nMod.o > b.log 2>&1 \
   && "$H/$XC" -q -A $A -H "$H" -c nMain.xc -o nMain.o >> b.log 2>&1 \
   && "$H/$XC" -q -A $A -H "$H" nMain.o nMod.o -o nprog >> b.log 2>&1; then
    out=$(./nprog 2>&1 | head -1)
    [ "$out" = "42" ] || bad "a program linked from objects: got '$out', want 42"
else
    bad "the object link fails"; head -5 b.log
fi
if "$H/$XC" -q -A $A -H "$H" -L . nMain.xc nMod.xc -o nprog2 > b.log 2>&1; then
    out=$(./nprog2 2>&1 | head -1)
    [ "$out" = "42" ] || bad "a program built from two sources: got '$out', want 42"
else
    bad "the two-source build fails"; head -5 b.log
fi
# Run from elsewhere: the run paths are absolute, not the working directory.
mkdir -p elsewhere && cd elsewhere || exit 1
out=$(../nprog 2>&1 | head -1)
[ "$out" = "42" ] || bad "run from another directory: got '$out', want 42"
[ $fail = 0 ] && echo "--- lib-runtime-objlink: pass ---" || { echo "--- lib-runtime-objlink: FAIL ---"; exit 1; }
