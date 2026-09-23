#!/bin/sh
# coffobj-diff.sh — the two COFF object readers must agree.
#
# The COFF twin of elfobj-diff.sh (task #50). The reference reads PE/COFF
# relocatables in XTPEWriter's `objectFromData:`; the port reads them in
# selfhost/asm/CoffObject.xc. `-A win64` linking against mingw depends on both
# agreeing about what an object CONTAINS.
#
# Inputs: mingw's libmingwex.a and libmsvcrt.a — real archives with COMDAT code
# sections, auxiliary symbol records and the .idata/.pdata/.xdata sections a
# linker must NOT take, none of which a hand-written object would exercise.
#
# Skips cleanly when no mingw sysroot is present.
set -u
cd "$(dirname "$0")/../.." || exit 1

BIN_DIR=${BIN_DIR:-bin/osx}
[ -d "$BIN_DIR" ] || BIN_DIR=bin/linux
ORACLE="$BIN_DIR/oracle-coffobj"
PORT="$BIN_DIR/coffobjdump"
MINGW=${XTC_MINGW_ROOT:-/opt/clang/win64/x86_64-w64-mingw32}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

[ -x "$ORACLE" ] || make -s oracle-coffobj >/dev/null 2>&1
[ -x "$PORT" ]   || make -s coffobjdump    >/dev/null 2>&1
# No pass=/fail= line here on purpose: all-diff scores a harness that COMPARED
# NOTHING as BROKEN, and a reader differential that could not run is that.
[ -x "$ORACLE" ] || { echo "--- coffobj-diff: DID NOT RUN (cannot build oracle-coffobj) ---"; exit 1; }
[ -x "$PORT" ]   || { echo "--- coffobj-diff: DID NOT RUN (cannot build coffobjdump) ---"; exit 1; }

inputs=""
for a in libmingwex.a libmsvcrt.a; do
    [ -f "$MINGW/lib/$a" ] && inputs="$inputs $MINGW/lib/$a"
done
if [ -z "$inputs" ]; then
    echo "--- coffobj-diff: SKIPPED (no mingw sysroot; set XTC_MINGW_ROOT) ---"
    exit 0
fi

pass=0; fail=0
for in in $inputs; do
    "$ORACLE" "$in" > "$WORK/o.txt" 2>/dev/null
    "$PORT"   "$in" > "$WORK/p.txt" 2>/dev/null
    if [ ! -s "$WORK/o.txt" ]; then
        echo "    $(basename "$in"): oracle produced nothing — NOT a pass"
        fail=$((fail + 1)); continue
    fi
    if cmp -s "$WORK/o.txt" "$WORK/p.txt"; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "    $(basename "$in"): differs"
        diff "$WORK/o.txt" "$WORK/p.txt" | head -8 | sed 's/^/      /'
    fi
done
echo "--- coffobj-diff: pass=$pass fail=$fail ---"
# NOTHING COMPARED is not a pass. An oracle failure — a file the REFERENCE could
# not build — is skipped, so a broken oracle turns the whole sweep into skips
# and the summary reads pass=0 fail=0. Only `fail` was ever checked, so that
# exited 0 and showed as a clean row in all-diff's table; it hid 961 uncompared
# files on ldx86-diff. private:docs/bugs/239.
if [ "$pass" -eq 0 ]; then
    echo "--- $(basename "$0"): NOTHING WAS COMPARED — this is not a pass"
    exit 1
fi
[ "$fail" = 0 ]
