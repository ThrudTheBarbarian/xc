#!/bin/bash
# run_rocks_gem.sh -- the `rocks-gem` gate: Rocks itself on GEM, without the board -- hostgem's GEM
# (the real desktop and AES, native on the Mac; frameworks/uxkit/hostgem) with Rocks built as its
# client (-D RK_HOSTGEM: the GEM branch of RKDriver on arm64).  The app must come up (its PASS
# line), and the framebuffer must show the window painted: the canvas is the window's background,
# not the black of a work area nobody cleared.  Writes /tmp/hostgem_fb.ppm.  macOS-only; needs
# GEM_DIR (the GEM desktop sources).
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
here=$(cd "$(dirname "$0")" && pwd)
ux=$(cd "$here/../../frameworks/uxkit" && pwd)
xcc=${XCC:-xcc}
export UX_GEM_DIR=${UX_GEM_DIR:-${GEM_DIR:-}}
case "$(uname)" in Darwin) ;; *) echo "== rocks-gem: skipped (hostgem is macOS-only) =="; exit 0 ;; esac
[ -n "$UX_GEM_DIR" ] || { echo "== rocks-gem: skipped (no GEM_DIR) =="; exit 0; }
echo "== rocks-gem: building host gemd + Rocks as its client =="
bash "$ux/hostgem/build_gemd.sh" >/dev/null || { echo "== rocks-gem: FAILED (gemd build) =="; exit 1; }
"$xcc" -A arm64 -D RK_HOSTGEM -I "$ux" -I "$here/xc" -L /tmp "$here/xc/rocks_main.xc" -o /tmp/xg_rocks -q \
  || { echo "== rocks-gem: FAILED (build) =="; exit 1; }
rm -f /tmp/hostgem_fb.ppm
/tmp/xg_hostgemd/host_gemd serve 4 >/tmp/hostgem_gemd.log 2>&1 & GPID=$!
sleep 1.5
UX_CLIENT=1 DYLD_LIBRARY_PATH=/tmp timeout 8 /tmp/xg_rocks >/tmp/hostgem_rocks.log 2>&1 & CPID=$!
wait $GPID; kill $CPID 2>/dev/null
grep -E '^(PASS|FAIL)' /tmp/hostgem_rocks.log | head -1
grep -q '^PASS' /tmp/hostgem_rocks.log || { echo "== rocks-gem: FAILED (the app did not come up) =="; exit 1; }
python3 - <<'PY' || { echo "== rocks-gem: FAILED =="; exit 1; }
d=open('/tmp/hostgem_fb.ppm','rb').read(); i=d.index(b'255\n')+4; px=d[i:]; W=1280
p=lambda x,y: tuple(px[(y*W+x)*3:(y*W+x)*3+3])
canvas=p(540,400)   # the middle of the (empty) canvas pane: the editor's blue grid
print(f"canvas pixel {canvas}")
assert canvas[2] - canvas[0] >= 15 and canvas[2] >= 200, "the window's work area is not painted"
PY
echo "== rocks-gem: OK — Rocks runs on GEM =="
