#!/bin/bash
# split-build.sh — build xcc from one object per source file, in parallel.
#
# The compiler's files import each other as <Name>, which finds the source
# through -I in the one-unit build and the module's interface (.xtc.iface)
# through -L here. So each object holds its own file's code (and a copy of the
# standard library, which the link commons), never a copy of the compiler
# files it imports.
#
#   1. one interface per compiler file (front end only, a tenth of a second)
#   2. one object per compiler file, against those interfaces
#   3. one link
#
#   XCC=<xcc> bash selfhost/tools/split-build.sh <out> [-A arm64] [-j N]
#
# The driver (selfhost/tools/xcc.xc) needs XCC_VERSION, as in the Makefile.
set -u
cd "$(dirname "$0")/../.." || exit 1
XCC=${XCC:-bin/$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )/xcc-xc}
OUT=${1:?the output path}; shift
ARCH=arm64; JOBS=8; EXTRA=()
while [ $# -gt 0 ]; do
    case "$1" in
        -A) ARCH=$2; shift 2 ;;
        -j) JOBS=$2; shift 2 ;;
        *) EXTRA+=("$1"); shift ;;
    esac
done
case "$ARCH" in
    arm64) LIB=support/arm64/lib ;;
    x86_64) LIB=support/x86_64/lib; EXTRA+=(-static) ;;
    win64) LIB=support/win64/lib ;;
    *) echo "split-build: no library directory for -A $ARCH"; exit 2 ;;
esac
V=$(cat VERSION)
W=${SPLIT_DIR:-build/split-$ARCH}
rm -rf "${W:?}"; mkdir -p "$W/if" "$W/obj"
DIRS="selfhost/lexer selfhost/preproc selfhost/parser selfhost/sema selfhost/ir selfhost/opt selfhost/codegen selfhost/asm selfhost/link selfhost/driver selfhost/tools"
SRC_I=(-I support/generic/lib -I "$LIB" -I selfhost/defs)
ALL_I=("${SRC_I[@]}"); for d in $DIRS; do ALL_I+=(-I "$d"); done
# The compiler's sources: the import closure of the driver, less the library.
FILES=$(python3 - "$DIRS" <<'PY'
import os, re, sys
dirs = sys.argv[1].split()
def find(name):
    for d in dirs:
        p = os.path.join(d, name + '.xc')
        if os.path.isfile(p):
            return p
# Dependencies first (the imports have no cycles), so each interface can be
# made against the interfaces of what it imports and describes its own file.
order, state = [], {}
def visit(n):
    p = find(n)
    if p is None or state.get(n) == 2:
        return
    if state.get(n) == 1:
        sys.exit('split-build: an import cycle through ' + n)
    state[n] = 1
    for m in re.findall(r'#import\s+<([A-Za-z0-9_]+)>', open(p).read()):
        visit(m)
    state[n] = 2
    order.append(p)
visit('xcc')
print('\n'.join(order))
PY
)
n=$(echo "$FILES" | wc -l | tr -d ' ')
step() { echo "[$(date +%H:%M:%S)] $*"; }
step "interfaces: $n files, in dependency order"
for f in $FILES; do
    b=$(basename "$f" .xc)
    "$XCC" -q -A "$ARCH" -H . -D XCC_VERSION="\"$V\"" "${SRC_I[@]}" -L "$W/if" --emit-iface \
        -o "$W/if/$b.xtc.iface" "$f" > "$W/if/$b.log" 2>&1 || echo "FAIL iface $f"
done
step "objects"
echo "$FILES" | xargs -P "$JOBS" -I{} sh -c '
    f="$1"; shift; b=$(basename "$f" .xc)
    "$@" -c -o "'"$W"'/obj/$b.o" "$f" > "'"$W"'/obj/$b.log" 2>&1 || echo "FAIL object $f"' _ {} \
    "$XCC" -q -O2 -A "$ARCH" -H . -D XCC_VERSION="\"$V\"" "${SRC_I[@]}" -L "$W/if" ${EXTRA[@]+"${EXTRA[@]}"}
fail=$(grep -l -E 'error' "$W"/if/*.log "$W"/obj/*.log 2>/dev/null)
if [ -n "$fail" ]; then echo "split-build: errors in:"; echo "$fail" | head -10; exit 1; fi
step "link"
# To a new name, then moved: a Mach-O rewritten in place at a path that is
# running (or was, and is cached) dies with SIGKILL.
"$XCC" -q -A "$ARCH" -H . ${EXTRA[@]+"${EXTRA[@]}"} -o "$OUT.new.$$" "$W"/obj/*.o || { echo "split-build: the link failed"; exit 1; }
mv -f "$OUT.new.$$" "$OUT"
step "done: $OUT"
