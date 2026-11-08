#!/bin/bash
# goal-order.sh — which goal a loop or a par block has (2026-11-08).
#
# A loop's or block's goal is its own :goal, else the goal of the loop or
# block it sits in, else the file's #goal, else the build's -fgoal=, else the
# built-in default: speed for a par block written in the source and for a
# loop --par-style makes a block of, accuracy for a plain loop. Read here from
# arm64 code, where speed fuses a multiply into the add after it and accuracy
# does not: each case is a function (or a block's run function) whose loop is
# `s = s + a[i] * b[i]`, and fuses or not as its goal says. Both compilers.
#
#   bash tests/driver/goal-order.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
# arm64 macOS code, which the Mac legs check.
[ "$(uname -s)" = Darwin ] || { echo "goal-order: skipped (not macOS)"; exit 0; }
PLAT=osx
XC=${XC:-bin/$PLAT/xcc-xc}
REF=${REF:-bin/$PLAT/xcc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0
fused() { grep -cE '\bf(madd|msub|nmadd|nmsub|mla|mls)\b' "$1"; }
body() { awk -v f="$2:" '$0 == f {p=1; next} p && /^_[A-Za-z]/ {exit} p' "$1" > "$1.fn"; echo "$1.fn"; }
# case NAME WANT(speed|accuracy) FILEHEAD FLAGS LOOPCODE [FN]
# FN: the function to read, _g by default; _ParImpl$0$run for the program's
# first block (the runtime's own blocks follow the program's).
case_() {
    local name=$1 want=$2 head=$3 flags=$4 code=$5 fn=${6:-_g}
    {
        printf '%s\n#import "Stdio.xc"\n#import "Par.xc"\n' "$head"
        printf 'float g(float* a, float* b, u32 n)\n{\n    float s = 0.0;\n    float* o = new float[4096];\n'
        printf '    %s\n' "$code"
        printf '    return s + o[0];\n}\n'
        printf 'i32 main(i32 argc, u8** argv)\n{\n    float* a = new float[4096];\n    float* b = new float[4096];\n'
        printf '    for (u32 i = 0; i < 4096; i++) :serial { a[i] = (float)i; b[i] = (float)argc; }\n'
        printf '    Stdio.printf("%%f\\n", (double)g(a, b, (u32)4096));\n    return 0;\n}\n'
    } > "$W/$name.xc"
    for c in "$XC" "$REF"; do
        n=$(basename "$c")
        "$c" -q -O2 -A arm64 -H . $flags -S -o "$W/$name.$n.s" "$W/$name.xc" > "$W/$name.$n.e" 2>&1 \
            || { echo "FAIL goal-order: $name does not build with $n: $(head -c 200 "$W/$name.$n.e")"; fail=1; continue; }
        f=$(body "$W/$name.$n.s" "$fn")
        [ -s "$f" ] || { echo "FAIL goal-order: $name: no $fn with $n"; fail=1; continue; }
        k=$(fused "$f")
        if [ "$want" = speed ]; then
            [ "$k" -gt 0 ] || { echo "FAIL goal-order: $name should fuse (speed) with $n, and does not"; fail=1; }
        else
            [ "$k" = 0 ] || { echo "FAIL goal-order: $name should not fuse (accuracy) with $n, and fuses $k"; fail=1; }
        fi
    done
}
L='for (u32 i = 0; i < n; i++) s = s + a[i] * b[i];'
LS='for (u32 i = 0; i < n; i++) :goal(speed) s = s + a[i] * b[i];'
LA='for (u32 i = 0; i < n; i++) :goal(accuracy) s = s + a[i] * b[i];'
OS="for (u32 r = 0; r < 2; r++) :goal(speed) $L"
OA="for (u32 r = 0; r < 2; r++) :goal(accuracy) $L"
WL='u32 i = 0; while (i < n) { s = s + a[i] * b[i]; i = i + 1; }'
CPU=--par-style=cpu
# Plain loops.
case_ plain          accuracy ""               "$CPU"             "$L"
case_ own-speed      speed    ""               "$CPU"             "$LS"
case_ file-speed     speed    "#goal speed"    "$CPU"             "$L"
case_ build-speed    speed    ""               "$CPU -fgoal=speed" "$L"
case_ file-over-build accuracy "#goal accuracy" "$CPU -fgoal=speed" "$L"
case_ own-over-file  accuracy "#goal speed"    "$CPU"             "$LA"
case_ outer-speed    speed    "#goal accuracy" "$CPU"             "$OS"
case_ outer-accuracy accuracy "#goal speed"    "$CPU"             "$OA"
case_ while-file     speed    "#goal speed"    "$CPU"             "$WL"
case_ while-outer    speed    ""               "$CPU"             "for (u32 r = 0; r < 2; r++) :goal(speed) { $WL }"
# Written blocks: speed unless something says accuracy.
PB='par blk :reduce(+ s) { for (u32 i in 0..n) s = s + a[i] * b[i]; }'
case_ block          speed    ""               "$CPU"             "$PB" '_ParImpl$0$run'
case_ block-file     accuracy "#goal accuracy" "$CPU"             "$PB" '_ParImpl$0$run'
case_ block-own      speed    "#goal accuracy" "$CPU"             "par blk :reduce(+ s) :goal(speed) { for (u32 i in 0..n) s = s + a[i] * b[i]; }" '_ParImpl$0$run'
case_ block-outer    accuracy ""               "$CPU"             "for (u32 r = 0; r < 2; r++) :goal(accuracy) { $PB }" '_ParImpl$0$run'
# A loop --par-style makes a block of: speed unless something says accuracy.
# An escape loop over the items (the shape a Mandelbrot is), which the
# compiler lifts whatever the goal.
LO='for (u32 i in 0..n) { float x = 0.0; float y = 0.0; u32 k = 0; while (k < 64 && x * x + y * y < 4.0) { float t = x * x - y * y + a[i]; y = 2.0 * x * y + b[i]; x = t; k = k + 1; } o[i] = (float)k; }'
case_ lifted         speed    ""               ""                 "$LO" '_ParImpl$0$run'
case_ lifted-build   accuracy ""               "-fgoal=accuracy"  "$LO" '_ParImpl$0$run'
case_ lifted-file    accuracy "#goal accuracy" ""                 "$LO" '_ParImpl$0$run'
[ $fail = 0 ] && echo "goal-order: ok"
exit $fail
