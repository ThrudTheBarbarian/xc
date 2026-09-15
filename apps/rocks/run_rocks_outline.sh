#!/bin/sh
# run_rocks_model.sh — the `rocks-outline` gate: the resource model and the
# flatten() that rebuilds the classic linked layout.  Neutral code, no driver,
# so it runs on every target the compiler supports.
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
set -e
here=$(cd "$(dirname "$0")" && pwd)
ux="$here/../../frameworks/uxkit"
xcc=${XCC:-xcc}
ARCH="${1:-arm64}"
command -v "$xcc" >/dev/null 2>&1 || { echo "== rocks-outline: no compiler ('$xcc'); set XCC =="; exit 2; }
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
# win64 wants the .exe on the -o path (the overnight suite carries a CEXT for
# the same reason); wasm32 derives both .wasm and .js from a bare name.
case "$ARCH" in win64) OUT="$work/rkoutline.exe" ;; *) OUT="$work/rkoutline" ;; esac
LIB=""
[ "$ARCH" = arm9 ] && LIB="-L ${GEMLIB:-}"
"$xcc" -A "$ARCH" -I "$ux" -I "$here/xc" $LIB "$here/xc/test_rkoutline.xc" -o "$OUT" -q
# arm9 targets the board and has no host runner, so a clean BUILD is the whole
# result there — the same rule the overnight suite uses.  Counting it as a
# failure would make every arm9 run read red for a reason that is not a defect.
if [ "$ARCH" = arm9 ]; then
  echo "== rocks-outline (arm9): BUILD OK (no host runner) =="; exit 0
fi
case "$ARCH" in
  wasm32) out=$(node "$work/rkoutline.js" 2>&1) ;;
  win64)  out=$(cd "$work" && WINEDEBUG=-all wine rkoutline.exe 2>&1) ;;
  *)      out=$("$OUT" 2>&1) ;;
esac
echo "$out" | tail -3
echo "$out" | grep -q "^PASS" || { echo "== rocks-outline ($ARCH): FAILED =="; exit 1; }
echo "== rocks-outline ($ARCH): OK =="
