#!/bin/bash
# arm64o3-diff.sh — the ported arm64 back end on OPTIMISED IR (private:docs/bugs/065).
#
# arm64-diff runs at -O0, which is the level nobody ships: `make corpus` and the
# driver default are both -O3. This is the same harness at 3, and it is RED —
# see 065. It is registered anyway, because a gap that is only visible when
# somebody remembers to pass an argument is the gap this project keeps finding.
exec bash "$(dirname "$0")/arm64-diff.sh" 3 "$@"
