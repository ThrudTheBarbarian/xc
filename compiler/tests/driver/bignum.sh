#!/bin/bash
# bignum.sh — RSA-size modular exponentiation in selfhost/link/Bignum.xc
# (#291), which macOS and APK signing and key generation use. A modulus over
# about 2528 bits overflowed the product buffer and gave a wrong result with
# no error (a 3072-bit signing key made an invalid signature).
# tests/link/bignum_modexp.xc computes modexp for 2048-, 3072- and 4096-bit
# odd moduli, each checked against Python's pow(), and the interleaved
# Montgomery multiply against the full product reduced.
#
#   bash tests/driver/bignum.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
command -v python3 > /dev/null || { echo "bignum: no python3, skipped"; exit 0; }
[ -x "$XC" ] || { echo "bignum: no $XC, skipped"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
"$XC" -q -O2 -H . -I selfhost/link -o "$W/bn" tests/link/bignum_modexp.xc > "$W/b" 2>&1 || { echo "FAIL bignum: no build: $(head -c 300 "$W/b")"; exit 1; }
"$W/bn" > "$W/got" || { echo "FAIL bignum: the program failed"; exit 1; }
python3 -I - "$W/got" <<'PY'
import sys
def pattern(b, seed, odd):
    out = bytearray()
    for i in range(b):
        v = (i * 37 + seed * 101 + (i >> 3) * 13) & 255
        if i == 0: v |= 128
        if odd and i == b - 1: v |= 1
        out.append(v)
    return int.from_bytes(out, 'big')
got = open(sys.argv[1]).read().split('\n')
bad = 0
for idx, b in enumerate([256, 384, 512]):
    n = pattern(b, 1, True); base = pattern(b - 1, 2, False); e = pattern(b, 3, False)
    if got[idx] != format(pow(base, e, n), '0%dx' % (2 * b)):
        print("FAIL bignum: %d-bit modexp differs from pow()" % (b * 8)); bad = 1
if got[3] != "montmul agrees":
    print("FAIL bignum: montMul differs from montReduce(mul)"); bad = 1
if not bad:
    print("bignum: ok")
sys.exit(bad)
PY
