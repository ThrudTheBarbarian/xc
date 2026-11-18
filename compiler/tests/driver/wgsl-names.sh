#!/bin/bash
# wgsl-names.sh — no WGSL identifier a par kernel declares spells a WGSL type.
#
# A captured scalar is held in a variable named after its field, f<k>. With 33
# or more captures field 32 was `var f32: f32;`, which shadows the type, so
# WebGPU rejected the kernel ("cannot use 'var f32' as type") and the block ran
# on the CPU. Field 16 was `f16`, the half-precision type. Those fields take a
# trailing underscore. A block capturing 40 scalars, built for wasm32 by both
# compilers: the WGSL must be the same, declare no f16/f32/f64 variable, and
# declare every field variable it uses.
#
#   bash tests/driver/wgsl-names.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
REF=${REF:-bin/$PLAT/xcc}
XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0

{
    echo '#import <Stdio.xc>'
    echo '#import "Par.xc"'
    echo 'float gOut[256];'
    echo 'i32 main(i32 argc, u8** argv)'
    echo '    {'
    sum=""
    for i in $(seq 0 39); do
        echo "    float a$i = (float)argc * $((i + 1)).0;"
        sum="$sum${sum:+ + }a$i"
    done
    echo '    par k :grid(16, 16)'
    echo '        {'
    echo "        gOut[par.y * 16 + par.x] = $sum;"
    echo '        }'
    echo '    Stdio.printf("%f\n", (double)gOut[3]);'
    echo '    return 0;'
    echo '    }'
} > "$W/k.xc"

cat > "$W/wgsl.py" <<'EOF'
import re, sys
b = open(sys.argv[1], 'rb').read()
i = b.find(b'// xcpar wgsl')
if i < 0:
    print('no WGSL kernel'); sys.exit(1)
s = b[i:b.find(b'\0', i)].decode()
open(sys.argv[2], 'w').write(s)
bad = re.findall(r'\b(?:var|let)\s+(f16|f32|f64)\b|\b(f16|f32|f64)\s*=[^=]|=\s*(f16|f32|f64)\s*;', s)
if bad:
    print('a variable named after a type: %s' % sorted({x for t in bad for x in t if x})); sys.exit(1)
declared = set(re.findall(r'\bvar\s+(f\d+_?)\s*:', s))
used = set(re.findall(r'\b(f\d+_?)\b(?!\s*[(<])', s)) - {'f16', 'f32', 'f64'}
if used - declared:
    print('field variables used but not declared: %s' % sorted(used - declared)); sys.exit(1)
if 'f32_' not in declared:
    print('field 32 is not f32_'); sys.exit(1)
EOF

for s in r x; do
    c=$REF; [ $s = x ] && c=$XC
    "$c" -q -O2 -A wasm32 -o "$W/$s" "$W/k.xc" > "$W/e" 2>&1 \
        || { echo "FAIL wgsl-names: $(basename "$c") does not build: $(head -c 200 "$W/e")"; fail=1; continue; }
    out=$(python3 "$W/wgsl.py" "$W/$s.wasm" "$W/$s.wgsl") \
        || { echo "FAIL wgsl-names: $(basename "$c"): $out"; fail=1; }
done
[ -f "$W/r.wgsl" ] && [ -f "$W/x.wgsl" ] && { cmp -s "$W/r.wgsl" "$W/x.wgsl" \
    || { echo "FAIL wgsl-names: the two compilers' WGSL differs"; fail=1; }; }
[ $fail = 0 ] && echo "wgsl-names: ok"
exit $fail
