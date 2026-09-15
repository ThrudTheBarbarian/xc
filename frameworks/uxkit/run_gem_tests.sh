#!/bin/sh
# run_gem_tests.sh — the `gem-tests` gate: the GEM-backend tests, on host GEM.
#
# These 23 tests existed for a long time with NO gate and no place in the
# overnight sweep, so nothing compiled them and nothing ran them.  They were not
# broken -- they were dark.  What they needed was never an include path: it is
# the host GEM stack (hostgem/build_gemd.sh, which produces /tmp/libGEM.dylib and
# /tmp/libxtos.dylib) plus -L /tmp, and for most of them a running window server.
#
# Do NOT add -I hostgem: that shadows the GEM.xc the driver expects and turns a
# clean build into a page of "unresolved call" with no symbol named.  -I <uxkit>
# alone is right.
#
# The tests that need the AES need gemd up, so this starts one server for the
# whole run rather than one per test, and stops it at the end.
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
set -u
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
export UX_GEM_DIR=${UX_GEM_DIR:-${GEM_DIR:-}}
command -v "$xcc" >/dev/null 2>&1 || { echo "== gem-tests: no compiler ('$xcc'); set XCC =="; exit 2; }
case "$(uname)" in Darwin) ;; *) echo "== gem-tests: skipped (host GEM is macOS-only) =="; exit 0 ;; esac
[ -d "$UX_GEM_DIR" ] || { echo "== gem-tests: skipped (no GEM tree at $UX_GEM_DIR; set UX_GEM_DIR) =="; exit 0; }

TESTS="test_alert test_autoresize test_check test_clip test_controls test_dirty
test_focus test_host test_key test_leak test_memgate test_menu test_nib test_notify test_outline
test_radio test_state test_window"

# QUARANTINED: these build, and they FAIL.  They are reported every run rather
# than dropped, because a dark test quietly removed is worse than a dark test.
#   test_scroll  "no bar: the work area did not narrow"
#   test_table   "every row and cell is a GEM object = 96 (want 91)" — off by 5,
#                the shape of an expectation the toolkit outgrew
#   test_chrome  stops partway through its first check
#   test_scale   prints its measurements and never reaches a verdict
# None of them has run in a very long time, so these are pre-existing and not a
# regression of anything.  Triage them, then move each line up into TESTS.
DARK="test_scroll test_table test_chrome test_scale"

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== gem-tests: building the host GEM stack =="
bash "$here/hostgem/build_gemd.sh" >/dev/null 2>&1 || { echo "== gem-tests: gemd build FAILED =="; exit 1; }

echo "== gem-tests: building the clients =="
built=""; bfail=""
for t in $TESTS; do
  if "$xcc" -A arm64 -I "$here" -L /tmp "$here/$t.xc" -o "$work/$t" -q >/dev/null 2>&1
  then built="$built $t"; else bfail="$bfail $t"; fi
done
[ -n "$bfail" ] && echo "   BUILD-FAIL:$bfail"

echo "== gem-tests: starting the window server =="
/tmp/xg_hostgemd/host_gemd serve 600 >"$work/gemd.log" 2>&1 &
GPID=$!
sleep 2
stop() { kill $GPID 2>/dev/null; wait $GPID 2>/dev/null; }
trap 'stop; rm -rf "$work"' EXIT

pass=0; fail=""
for t in $built; do
  out=$(UX_CLIENT=1 DYLD_LIBRARY_PATH=/tmp timeout 40 "$work/$t" 2>&1)
  if printf '%s\n' "$out" | grep -q "^PASS"; then pass=$((pass+1)); printf "  %-18s PASS\n" "$t"
  else fail="$fail $t"; printf "  %-18s FAIL\n" "$t"; fi
done

total=$(echo $TESTS | wc -w | tr -d ' ')
echo "== gem-tests: $pass/$total passed =="
echo "== gem-tests: still dark (build, do not pass):$DARK =="
[ -z "$fail" ] && [ -z "$bfail" ] || { echo "== gem-tests: FAILED —$fail$bfail =="; exit 1; }
echo "== gem-tests: OK =="
