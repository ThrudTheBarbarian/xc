#!/bin/bash
# a9o3-diff.sh — the ported AArch32 back end on OPTIMISED IR (task #48).
#
# a9-diff runs at -O0, which is not the level anybody ships: `make corpus`
# and the driver default are both -O3. This is the same harness at 3.
#
# It is NOT a check-in gate. Running the whole -O3 matrix is an overnight job
# and its failures are a backlog to work through (task #49, o3-nightly.sh), not
# a reason to block a commit. It is registered so the gap cannot go back to
# being invisible — a divergence that only shows up when somebody remembers to
# pass an argument is exactly the gap this project keeps rediscovering.
exec bash "$(dirname "$0")/a9-diff.sh" 3 "$@"
