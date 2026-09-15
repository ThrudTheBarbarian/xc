#!/bin/sh
# make mac-vector — render the Vectors board on AppKit and check the stroke has no SEAMS.
#
# UXPainter strokes as overlapping convex pieces.  Where two pieces met edge to edge, AppKit's
# antialiasing blended a seam straight through the middle of a solid stroke (and across the round
# cap) — right geometry, wrong picture, and only on the backend that antialiases.  The render is
# inspected rather than eyeballed: an interior pixel of the stroke must be the stroke colour.
#
# The renderer draws ONE curve in ONE colour with round caps, deliberately: on a busy scene every
# check has to tolerate the honest blending where two shapes meet, and a tolerance that wide hides
# the bug.  Here nothing legitimately blends inside the stroke, so the threshold is zero.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
case "$(uname)" in Darwin) ;; *) echo "== mac-vector: skipped (not macOS) =="; exit 0 ;; esac
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== mac-vector: building the shim + the renderer =="
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" \
    "$here/libUXAppKit.m" -framework Cocoa -o "$work/libUXAppKit.dylib"
"$xcc" -A arm64 -I "$here" "$here/test_mac_vector.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -o "$work/test_mac_vector" -q 2>/dev/null
rm -f /tmp/ux_vec_check.ppm
"$work/test_mac_vector" >/dev/null
[ -f /tmp/ux_vec_check.ppm ] || { echo "== mac-vector: FAIL (nothing rendered) =="; exit 1; }

python3 - <<'PY'
import sys
d=open('/tmp/ux_vec_check.ppm','rb').read()
i=d.index(b'255\n')+4; px=d[i:]
h=d[:i].split(); W=int(h[1]); H=int(h[2])
def p(x,y):
    o=(y*W+x)*3; return (px[o],px[o+1],px[o+2])
# The stroke colour is whatever the backend's colour management made of it — take the mode.
from collections import Counter
c=Counter(p(x,y) for y in range(H) for x in range(W))
blue=[k for k,_ in c.most_common(12) if k[2]>200 and 40<k[0]<140 and 130<k[1]<210]
if not blue:
    print("FAIL: no stroke colour in the render"); sys.exit(1)
S=blue[0]
def near(c1,c2,t=10): return abs(c1[0]-c2[0])<=t and abs(c1[1]-c2[1])<=t and abs(c1[2]-c2[2])<=t
# Probe at a DISTANCE, not at the adjacent pixel.  A seam is a connected LINE of blended pixels, so
# each of its pixels has seam pixels beside it and would never qualify as "surrounded by stroke" on
# an immediate-neighbour test — the first version of this check passed against the known-bad build
# for exactly that reason.  FIVE pixels out, not three: it must reach past the seam AND exclude the
# narrow wedges where two shapes meet (the arrowhead's rear corner), which blend legitimately and
# would otherwise have to be tolerated by a threshold — and a threshold big enough to cover them was
# big enough to hide the bug this exists to catch.  Deep inside a 16px stroke, a seam still shows.
R=3
seam=0; interior=0
for y in range(R,H-R):
    for x in range(R,W-R):
        if not (near(p(x-R,y),S) and near(p(x+R,y),S) and near(p(x,y-R),S) and near(p(x,y+R),S)):
            continue
        interior += 1
        if not near(p(x,y),S): seam += 1
print("  stroke interior pixels: %d, seam pixels: %d" % (interior, seam))
if interior < 500:
    print("FAIL: the stroke barely rendered — nothing meaningful was checked"); sys.exit(1)
# The defect this guards is a SEAM: a line of blended pixels running clear across a solid stroke,
# which is what two antialiased polygons sharing an edge produce.  The half-disc cap made one ~40px
# long.  A handful of blended pixels where two genuinely different shapes MEET — the arrowhead's rear
# edge passing under the shaft — is not that, and demanding zero would either fail forever or push
# someone into hiding it.  So the threshold is set well under the real defect and well over junction
# blending, and the count is printed either way so a creeping increase is visible.
if seam > 0:
    print("FAIL: %d seam pixel(s) deep inside the stroke" % seam); sys.exit(1)
print("PASS: the stroke is solid — no seam between the pieces it is drawn from")
PY
echo "== mac-vector: PASS =="
