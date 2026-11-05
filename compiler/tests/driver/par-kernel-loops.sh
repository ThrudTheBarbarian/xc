#!/bin/bash
# par-kernel-loops.sh — a par kernel's counted inner loop, as nbody writes it
# (a loop over every body calling Math.sqrt), reaches the GPU in the shape a
# GPU runs well (issue #7):
#
#   1. Math.sqrt is the pure FSqrt and its class's init guard is gone, so the
#      loads that do not change in the loop (px[i]) leave it, and
#   2. the loop, a constant trip of whole groups of four, runs as four copies
#      counted by one: its test compares with the number of groups (1024 / 4
#      = 256), not with the trip, and the module has four sqrts;
#   3. a kernel writing a byte array declares it 8-bit storage
#      (StorageBuffer8BitAccess) and stores each byte plainly, with no atomics
#      on its word, and its header says so (` bytes8`) for the runtime.
#
# Read from the SPIR-V module the arm64-linux build carries; both compilers
# must write the same module, and spirv-val (when installed) must accept it.
#
#   bash tests/driver/par-kernel-loops.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$([ "$(uname -s)" = Darwin ] && echo osx || echo linux)
REF=${REF:-bin/$PLAT/xcc}; XC=${XC:-bin/$PLAT/xcc-xc}
W=$(mktemp -d /tmp/par-kernel-loops.XXXX)
trap 'rm -rf "$W"' EXIT
fail=0

cat > "$W/k.xc" <<'EOF'
#import "Stdio.xc"
#import "Math.xc"
#import "Par.xc"
#define N 1024
float px[N];
float py[N];
float mass[N];
float fx[N];
i32 main(void)
    {
    for (u32 i in 0..N)
        {
        px[i] = (float)(i % (u32)37);
        py[i] = (float)(i % (u32)41);
        mass[i] = 1.0f;
        }
    par
        {
        for (u32 i in 0..N)
            {
            float ax = 0.0f;
            for (u32 j in 0..N)
                {
                float dx = px[j] - px[i];
                float dy = py[j] - py[i];
                float d2 = dx * dx + dy * dy + 0.0001f;
                ax = ax + mass[j] * dx / (d2 * Math.sqrt(d2));
                }
            fx[i] = ax;
            }
        }
    Stdio.printf("%d\n", (i32)fx[3]);
    return 0;
    }
EOF

cat > "$W/b.xc" <<'EOF'
#import "Stdio.xc"
#import "Par.xc"
#define N 65536
u8 img[N];
i32 main(void)
    {
    par
        {
        for (u32 i in 0..N)
            img[i] = (u8)((i * (u32)2654435761) >> (u32)24);
        }
    u32 s = (u32)0;
    for (u32 i in 0..N) s = s + (u32)img[i];
    Stdio.printf("%u\n", s);
    return 0;
    }
EOF

cat > "$W/spv.py" <<'EOF'
import struct, sys
b = open(sys.argv[1], 'rb').read()
i = b.find(struct.pack('<I', 0x07230203))
if i < 0:
    print('no SPIR-V module'); sys.exit(1)
w = lambda o: struct.unpack_from('<I', b, o)[0]
o = i + 20
consts, ults, sqrts = {}, [], 0
caps8, atomics = False, 0
while o + 4 <= len(b):
    x = w(o); n = x >> 16; op = x & 0xffff
    if n == 0 or (op > 400 and op not in (4446, 4447, 5341)):
        break
    if op == 17 and w(o + 4) == 4448:  # OpCapability StorageBuffer8BitAccess
        caps8 = True
    if op in (240, 241, 242):          # OpAtomicAnd / Or / Xor... (atomics)
        atomics += 1
    if op == 43 and n == 4:            # OpConstant type id value
        consts[w(o + 8)] = w(o + 12)
    elif op == 176:                    # OpULessThan type res a b
        ults.append(w(o + 16))
    elif op == 12 and n >= 6 and w(o + 16) == 31:   # OpExtInst ... GLSL Sqrt
        sqrts += 1
    o += 4 * n
open(sys.argv[2], 'wb').write(b[i:o])
bounds = sorted(set(consts[c] for c in ults if c in consts))
print('bounds', ' '.join(str(v) for v in bounds), 'sqrts', sqrts, 'caps8', int(caps8), 'atomics', atomics)
EOF

for C in "$REF" "$XC"; do
    n=$(basename "$C")
    if ! "$C" -q -O2 -A arm64-linux -o "$W/k.$n" "$W/k.xc" 2> "$W/err.$n"; then
        echo "FAIL $n: build"; head -5 "$W/err.$n"; fail=1; continue
    fi
    r=$(python3 "$W/spv.py" "$W/k.$n" "$W/k.$n.spv")
    case " $r " in
        *" 256 "*) ;;
        *) echo "FAIL $n: the inner loop does not count groups of four ($r)"; fail=1;;
    esac
    case " $r " in
        *" 1024 "*) echo "FAIL $n: a loop still compares with the trip ($r)"; fail=1;;
    esac
    case "$r" in
        *"sqrts 4 "*) ;;
        *) echo "FAIL $n: not four copies of the body ($r)"; fail=1;;
    esac
    if command -v spirv-val >/dev/null 2>&1 && ! spirv-val "$W/k.$n.spv"; then
        echo "FAIL $n: spirv-val"; fail=1
    fi
done
if [ -f "$W/k.xcc.spv" ] && [ -f "$W/k.xcc-xc.spv" ] && ! cmp -s "$W/k.xcc.spv" "$W/k.xcc-xc.spv"; then
    echo "FAIL: the two compilers write different SPIR-V"; fail=1
fi

for C in "$REF" "$XC"; do
    n=$(basename "$C")
    if ! "$C" -q -O2 -A arm64-linux -o "$W/b.$n" "$W/b.xc" 2> "$W/err.$n"; then
        echo "FAIL $n: byte kernel build"; head -5 "$W/err.$n"; fail=1; continue
    fi
    r=$(python3 "$W/spv.py" "$W/b.$n" "$W/b.$n.spv")
    case "$r" in *"caps8 1 atomics 0") ;; *) echo "FAIL $n: the byte array is not plain 8-bit storage ($r)"; fail=1;; esac
    strings "$W/b.$n" | grep -q 'xcpar size=.* bytes8' || { echo "FAIL $n: the header does not say bytes8"; fail=1; }
    if command -v spirv-val >/dev/null 2>&1 && ! spirv-val --target-env vulkan1.3 "$W/b.$n.spv"; then
        echo "FAIL $n: spirv-val (byte kernel)"; fail=1
    fi
done
if [ -f "$W/b.xcc.spv" ] && [ -f "$W/b.xcc-xc.spv" ] && ! cmp -s "$W/b.xcc.spv" "$W/b.xcc-xc.spv"; then
    echo "FAIL: the two compilers write different SPIR-V for the byte kernel"; fail=1
fi
[ $fail = 0 ] && echo "par-kernel-loops: ok"
exit $fail
