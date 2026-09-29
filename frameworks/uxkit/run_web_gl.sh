#!/bin/sh
# The web (WebGL2) GL SURFACE (`web-gl`).  Sibling of run_win32_gl.sh / run_gtk_gl.sh:
# the driver owns the surface (a host canvas made at realization), makes the context,
# sets the viewport from the view's frame and presents; the app owns the renderer.  On
# the web the entry points are HOST IMPORTS the renderer declares, and glProc answers 0
# by design (a pointer to a wasm import traps when called), so the gate pins that and
# exercises an entry point as an import instead.  The rig has no GPU, so this proves the
# SURFACE PLUMBING and not a shader draw -- the same honest limit as the Win32 gate.
# Skips cleanly when node is absent.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
command -v node >/dev/null || { echo "== web-gl: skipped (no node on PATH) =="; exit 0; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== web-gl: building test_web_gl for wasm32 =="
"$xcc" -A wasm32 -I "$here" -o "$work/test_web_gl" "$here/test_web_gl.xc" -q 2>/dev/null

echo "== web-gl: running under node + the recording rig =="
out=$(node --require "$here/ux_web_node.js" "$work/test_web_gl.js")
printf '%s\n' "$out"

fail=0
for want in 'glKind=3' 'gl created=1 current=1 viewport 640 400' '^PASS'; do
  printf '%s\n' "$out" | grep -q "$want" || { echo "  missing: $want"; fail=1; }
done
[ "$fail" = 0 ] || { echo "== web-gl: FAIL =="; exit 1; }
echo "== web-gl: OK =="
