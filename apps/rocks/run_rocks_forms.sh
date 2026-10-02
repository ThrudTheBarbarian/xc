#!/bin/sh
# run_rocks_forms.sh — the `rocks-forms` gate: layout variants -- forms, logical ids,
# orientation and the UXNB v2 chunk, checked through UXKit's own loader.  Neutral, no driver,
# so it runs on every target the compiler supports.
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
set -e
here=$(cd "$(dirname "$0")" && pwd)
ux="$here/../../frameworks/uxkit"
xcc=${XCC:-xcc}
ARCH="${1:-arm64}"
command -v "$xcc" >/dev/null 2>&1 || { echo "== rocks-forms: no compiler ('$xcc'); set XCC =="; exit 2; }
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
# win64 wants the .exe on the -o path (the overnight suite carries a CEXT for
# the same reason); wasm32 derives both .wasm and .js from a bare name.
case "$ARCH" in win64) OUT="$work/rkforms.exe" ;; *) OUT="$work/rkforms" ;; esac
LIB=""
[ "$ARCH" = arm9 ] && LIB="-L ${GEMLIB:-}"
"$xcc" -A "$ARCH" -I "$ux" -I "$here/xc" $LIB "$here/xc/test_rkforms.xc" -o "$OUT" -q
# arm9 targets the board and has no host runner, so a clean BUILD is the whole
# result there — the same rule the overnight suite uses.  Counting it as a
# failure would make every arm9 run read red for a reason that is not a defect.
if [ "$ARCH" = arm9 ]; then
  echo "== rocks-forms (arm9): BUILD OK (no host runner) =="; exit 0
fi
case "$ARCH" in
  wasm32) out=$(node "$work/rkforms.js" 2>&1) ;;
  win64)  out=$(cd "$work" && WINEDEBUG=-all wine rkforms.exe 2>&1) ;;
  *)      out=$("$OUT" 2>&1) ;;
esac
echo "$out" | tail -3
echo "$out" | grep -q "^PASS" || { echo "== rocks-forms ($ARCH): FAILED =="; exit 1; }
echo "== rocks-forms ($ARCH): OK =="
