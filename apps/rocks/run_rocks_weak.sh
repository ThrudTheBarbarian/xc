#!/bin/sh
# run_rocks_weak.sh — the `rocks-weak` gate: weak-reference semantics.
#
# These four probes were written while chasing bug 036 (a canvas crash that was a
# use-after-free) and were deliberately NOT gates while they failed, so the tree
# could stay green and honest.  All four pass on xcc 0.6, so they become a gate:
# what they cover is subtle, invisible at runtime until something segfaults, and
# has now regressed once.
#
#   probe_weak6  a returned weak field is not over-released
#   probe_weak7  which READS of a weak field are handled (return, ternary, local,
#                argument, cast)
#   probe_weak8  what happens to a value ASSIGNED INTO a weak slot
#   probe_weak9  who consumes the +1 of a returned value, weak- and strong-typed
#
# MallocScribble makes the over-release probes honest — without it, freed memory
# keeps its contents long enough to pass while broken.  The leak probes count
# live objects through a dealloc override, so they need no help.
set -e
here=$(cd "$(dirname "$0")" && pwd)
ux="$here/../../frameworks/uxkit"
xcc=${XCC:-xcc}
command -v "$xcc" >/dev/null 2>&1 || { echo "== rocks-weak: no compiler ('$xcc'); set XCC =="; exit 2; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
fails=""
for p in probe_weak6 probe_weak7 probe_weak8 probe_weak9; do
  "$xcc" -A arm64 -I "$ux" -I "$here/xc" "$here/xc/$p.xc" -o "$work/$p" -q
  out=$(MallocScribble=1 "$work/$p" 2>&1) || true
  printf '%s\n' "$out" | sed 's/^/  /'
  printf '%s\n' "$out" | grep -q "^PASS" || fails="$fails $p"
done
[ -z "$fails" ] || { echo "== rocks-weak: FAILED —$fails =="; exit 1; }
echo "== rocks-weak: OK =="
