#!/bin/sh
# run_overnight_tests.sh — build + run every headless test added in the overnight session (arm64).
# Each test prints its own PASS / FAIL line; this tallies them.  Pass -A <arch> to target win64/arm9
# (win64 runs under wine; arm9 needs GEMLIB set in build.env).
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
set -e
ARCH="${1:-arm64}"
# The compiler: $XCC like every other runner here, `xcc` only if it is on PATH.
# This used to be a bare `xcc` with its stderr discarded, so an xcc that was not
# on PATH reported "0 passed, 60 failed" — every test a BUILD-FAIL, which reads
# exactly like catastrophic breakage rather than a missing binary.
xcc=${XCC:-xcc}
command -v "$xcc" >/dev/null 2>&1 || { echo "== $ARCH: no compiler ('$xcc'); set XCC or put xcc on PATH =="; exit 2; }
WORK="$(mktemp -d)"
TESTS="test_range test_curves test_painter test_undo test_indexset test_regex test_log test_binaryheap test_color test_predicate \
test_numberformatter test_date test_eventrecorder test_breadcrumb test_collectionview test_toolbar \
test_path test_font test_pasteboard test_dragsession test_searchindex test_expression \
test_operationqueue test_keyvaluestore test_nibv2 test_null test_filechooser test_bag test_attributedstring test_textlayout test_url test_gradient test_json test_characterset test_text test_timer test_shapepath test_data test_cache test_viewport test_animation test_progress test_statemachine test_image test_slider test_segmented test_tabview test_csv test_markdown test_colorlist test_stepper test_progressbar test_sortdescriptor test_validator test_popupbutton test_datepicker test_combobox test_colorpanel test_nav test_integration"
# win64 binaries run under wine; native archs run directly. (arm9 has no host runner — build-only.)
# arm9 also needs the loader's build dir on the library path: without libc.so nothing links, and the
# whole run reports BUILD-FAIL for every test — which looks exactly like a real regression and is not.
# wasm32 compiles to $t.wasm + $t.js (the universal loader) and runs under node — CEXT is what the
# -o path carries (none: xcc derives both outputs), EXT is what the runner executes (.js).
EXT=""; CEXT=""; RUN=""; LIB=""
case "$ARCH" in
  win64)  EXT=".exe"; CEXT=".exe"; RUN="env WINEDEBUG=-all wine" ;;
  arm9)   EXT=".so";  CEXT=".so";  LIB="-L ${GEMLIB:-}" ;;
  wasm32) EXT=".js";  RUN="node" ;;
  android) EXT=""; ;;                    # aarch64 ELF PIE, pushed + run over adb shell
esac
if [ "$ARCH" = wasm32 ] && ! command -v node >/dev/null; then
  echo "== wasm32: skipped (no node on PATH) =="; exit 0
fi
# android runs on a live emulator/device: a missing one is a loud SKIP, never a pass.
ADB="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"
if [ "$ARCH" = android ]; then
  { [ -x "$ADB" ] && "$ADB" get-state >/dev/null 2>&1; } || { echo "== android: skipped (no adb device) =="; exit 0; }
fi
if [ "$ARCH" = arm9 ] && [ ! -d "${GEMLIB:-}" ]; then
  echo "== arm9: skipped (no loader build dir; set GEMLIB) =="; exit 0
fi
pass=0; fail=0
for t in $TESTS; do
  if "$xcc" -A "$ARCH" -I . $LIB -o "$WORK/$t$CEXT" "$t.xc" -q 2>/dev/null; then
    if [ "$ARCH" = arm9 ]; then
      # No host runner for the board: a clean BUILD is the whole result here.  Counting an
      # unrunnable binary as a failure made every arm9 run read 0/56 and hid real breakage.
      printf "  %-22s %s\n" "$t" "BUILD-OK"; pass=$((pass+1)); continue
    fi
    if [ "$ARCH" = android ]; then
      "$ADB" push "$WORK/$t" /data/local/tmp/uxt >/dev/null 2>&1
      r=$("$ADB" shell "chmod +x /data/local/tmp/uxt && /data/local/tmp/uxt" 2>/dev/null | grep -oE "PASS|FAIL: [0-9]+" | head -1)
    else
      r=$($RUN "$WORK/$t$EXT" 2>/dev/null | grep -oE "PASS|FAIL: [0-9]+" | head -1)
    fi
    printf "  %-22s %s\n" "$t" "$r"
    [ "$r" = "PASS" ] && pass=$((pass+1)) || fail=$((fail+1))
  else
    printf "  %-22s BUILD-FAIL\n" "$t"; fail=$((fail+1))
  fi
done
# The UMBRELLA (UXKit.xc -> libUXKit.so) is what the board links, and nothing else here builds it: it had
# silently stopped compiling — UXGemDriver named UXPopUpButton with nobody importing it — because
# every test imports the individual .xc files instead.  Build it too, on the arch that ships it.
if [ "$ARCH" = arm9 ]; then
  if "$xcc" -A arm9 -I . $LIB --emit-lib UXKit.xc -o "$WORK/libUXKit.so" -q 2>"$WORK/umbrella.err"; then
    printf "  %-22s %s\n" "libUXKit.so (umbrella)" "BUILD-OK"; pass=$((pass+1))
  else
    printf "  %-22s %s\n" "libUXKit.so (umbrella)" "BUILD-FAIL"; fail=$((fail+1))
    grep -iE "error" "$WORK/umbrella.err" | head -3
  fi
fi
echo "=== $pass passed, $fail failed ($ARCH) ==="
rm -rf "$WORK"
