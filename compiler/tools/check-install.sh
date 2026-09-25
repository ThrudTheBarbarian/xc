#!/bin/sh
# check-install.sh — guard what `make install` and `make dist` ship.
#
# Two checks, different in kind:
#
#   RULES   A property of the repo alone, so a hard failure. What ships is the
#           Makefile's ship list (SHIP_NAMES paired with SHIP_OSX, SHIP_LINUX
#           and SHIP_WIN64), and THE GOLDEN RULE holds: no binary built from the
#           Objective-C sources ships, under any name. So every list pairs
#           one-to-one with SHIP_NAMES, no entry is an Objective-C build, and
#           every shipped xc tool is compiled by the stage-2 xc compiler.
#
#   PATH    The binary that would actually RUN under each shipped name matches
#           the one the build produced for it. Environment-dependent, so it
#           fails only on unambiguous staleness: the files differ AND the build
#           is newer. XTC_ALLOW_STALE_PATH=1 turns that into a note.
#
# Tasks #1000 and #1005 were a binary the build fixed but the install never
# shipped, so the repo had the fix and the developer's PATH did not. The PATH
# check is what catches that shape now.
#
# Exit 0 = both clean. Exit 1 = a real problem.
set -u
cd "$(dirname "$0")/.." || exit 1

fails=0
notes=0
notonpath=0

ship=$(make -s print-ship 2>/dev/null) || { echo "FAIL  make print-ship failed"; exit 1; }
val() { printf '%s\n' "$ship" | sed -n "s/^$1=//p"; }
NAMES=$(val SHIP_NAMES)
OBJC=$(val OBJC_BUILT_OSX)
XC2=$(val XCC_XC2_BIN)
count() { set -- $1; echo $#; }
n=$(count "$NAMES")

# ---- RULES ---------------------------------------------------------------------------------
for list in SHIP_OSX SHIP_LINUX SHIP_WIN64; do
    entries=$(val $list)
    if [ "$(count "$entries")" -ne "$n" ]; then
        echo "FAIL  $list has $(count "$entries") entries for $n names in SHIP_NAMES"
        echo "      ($list: $entries)"
        fails=$((fails + 1))
    fi
    for e in $entries; do
        for o in $OBJC; do
            if [ "$(basename "$e")" = "$(basename "$o")" ] && [ "$(dirname "$e")" = "$(dirname "$o")" ]; then
                echo "FAIL  $list ships $e, which is an Objective-C build (THE GOLDEN RULE)"
                fails=$((fails + 1))
            fi
        done
    done
done
# Every shipped xc tool's rule must compile with the stage-2 compiler. A rule
# that invokes $(XTC_BIN) is compiling with the Objective-C build.
for v in XCC_SIGN_XC_BIN XCC_SIGN_XC_LINUX_BIN XCC_SIGN_XC_WIN64_BIN \
         XCC_AS_XC_BIN XCC_AS_XC_LINUX_BIN XCC_AS_XC_WIN64_BIN \
         XCC_XC_LINUX_BIN XCC_XC_WIN64_BIN XCC_XC2_BIN; do
    recipe=$(awk -v v="$v" '
      $0 ~ "^\\$\\(" v "\\):" { r = 1; cont = ($0 ~ /\\$/); next }
      r && cont { cont = ($0 ~ /\\$/); next }
      r && /^\t/ { print; next }
      r && !/^\t/ { r = 0 }' Makefile)
    if [ -z "$recipe" ]; then
        echo "FAIL  no rule found for \$($v)"
        fails=$((fails + 1))
    elif printf '%s' "$recipe" | grep -q 'XTC_BIN)'; then
        echo "FAIL  \$($v) is compiled by \$(XTC_BIN), the Objective-C build (THE GOLDEN RULE)"
        fails=$((fails + 1))
    fi
done

# ---- PATH ----------------------------------------------------------------------------------
# Only for binaries that have actually been built — an unbuilt tool is not drift.
set -- $NAMES
for path in $(val SHIP_OSX); do
    b=$1; shift
    [ -f "$path" ] || continue
    onpath=$(command -v "$b" 2>/dev/null) || onpath=""
    if [ -z "$onpath" ]; then
        notonpath=$((notonpath + 1))
        continue
    fi
    [ "$onpath" -ef "$path" ] && continue
    if cmp -s "$path" "$onpath"; then continue; fi

    if [ "$path" -nt "$onpath" ]; then
        echo "FAIL  $b: the copy on PATH is STALE"
        echo "      built:   $path"
        echo "      running: $onpath"
        echo "      A test that fails against the running one and passes against the built one is"
        echo "      not a compiler bug.  Run make install, or set XTC_ALLOW_STALE_PATH=1 if this is deliberate."
        if [ "${XTC_ALLOW_STALE_PATH:-0}" = "1" ]; then
            echo "      (XTC_ALLOW_STALE_PATH=1 — not counted as a failure)"
        else
            fails=$((fails + 1))
        fi
    else
        echo "note  $b: differs from $onpath, which is not older than the build — not stale, just not ours"
        notes=$((notes + 1))
    fi
done

if [ "$notonpath" -gt 0 ]; then
    echo "note  $notonpath built binary/binaries are not on PATH — run 'make install'"
    echo "      and put the printed bin directory on PATH (default /opt/xcc/<version>/bin)."
    notes=$((notes + 1))
fi

if [ "$fails" -gt 0 ]; then
    echo ""
    echo "=== check-install: $fails problem(s) ==="
    exit 1
fi
if [ "$notes" -gt 0 ]; then
    echo "=== check-install: OK ($notes note(s) above are not failures) ==="
else
    echo "=== check-install: OK (the ship lists hold only xc-built tools, and PATH matches the build) ==="
fi
exit 0
