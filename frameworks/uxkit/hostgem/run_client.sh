#!/bin/bash
# run_client.sh — the milestone-2 integration test: build the host gemd + the UXKit kitchen-sink client
# (native arm64), run them together over the POSIX shim, and assert the window composited by reading
# the framebuffer back (a "screen grab").  Writes /tmp/hostgem_fb.ppm for inspection.  macOS-only.
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
UXKit=$(cd "$HERE/.." && pwd)
export UX_GEM_DIR=${UX_GEM_DIR:-${GEM_DIR:-}}
xcc=${XCC:-xcc}

echo "== building host gemd + dylibs =="
bash "$HERE/build_gemd.sh" >/dev/null || { echo "gemd build failed"; exit 1; }
echo "== building the UXKit kitchen-sink client (xcc -A arm64) =="
"$xcc" -A arm64 -I "$UXKit" -L /tmp "$UXKit/ks_a9.xc" -o /tmp/xg_ks || { echo "client build failed"; exit 1; }

echo "== running gemd (server) + the client, grabbing the framebuffer =="
UX_GEM_DIR=$UX_GEM_DIR /tmp/xg_hostgemd/host_gemd serve 4 >/tmp/hostgem_gemd.log 2>&1 & GPID=$!
sleep 1.5
UX_CLIENT=1 UX_GEM_DIR=$UX_GEM_DIR DYLD_LIBRARY_PATH=/tmp timeout 8 /tmp/xg_ks >/tmp/hostgem_client.log 2>&1 & CPID=$!
wait $GPID; kill $CPID 2>/dev/null

python3 - <<'PY'
from collections import Counter
d=open('/tmp/hostgem_fb.ppm','rb').read(); i=d.index(b'255\n')+4; px=d[i:]; W=1280
c=Counter()
for y in range(92,508,3):
    for x in range(122,578,3):
        o=(y*W+x)*3; c[(px[o],px[o+1],px[o+2])]+=1
n=len(c)
print(f"window rect: {n} distinct colours; top: {c.most_common(3)}")
print("PASS: the UXKit kitchen-sink composited into the host GEM framebuffer" if n>20
      else "FAIL: the window did not composite")
PY
echo "framebuffer written to /tmp/hostgem_fb.ppm"
