#!/usr/bin/env bash
# generate-oracles.sh — snapshot the legacy AST codegen's stdout
# for every fixture in tests/fixtures/*.xc.
#
# For each fixture:
#   1. Compile with `${LEGACY_XTC} -m xl <file>.xc -o /tmp/oracle.xex`
#   2. Simulate with `${LEGACY_XTS} -d /tmp/oracle.xex`
#   3. Save the captured stdout to tests/fixtures/<name>.expected.out
#
# Fixtures the legacy codegen rejects are recorded in
# tests/fixtures/.unoracleable along with the first error line —
# the new corpus harness skips its oracle-diff for those.
#
# Tunables (override via env):
#   LEGACY_XTC  the earlier xcc binary (set in build.env)
#   LEGACY_XTS  the earlier xcc-sim-6502 binary (set in build.env)
#   TIMEOUT     default 10 (seconds per fixture, runtime cap on xts)
#
# Idempotent: re-running overwrites existing oracles.

set -uo pipefail

_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
LEGACY_XTC="${LEGACY_XTC:-}"
LEGACY_XTS="${LEGACY_XTS:-}"
TIMEOUT="${TIMEOUT:-10}"

FIXTURE_DIR="tests/fixtures"
UNORACLE="${FIXTURE_DIR}/.unoracleable"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

if [[ ! -x "$LEGACY_XTC" ]]; then
    echo "error: legacy xtc not found at $LEGACY_XTC" >&2
    exit 1
fi
if [[ ! -x "$LEGACY_XTS" ]]; then
    echo "error: legacy xts not found at $LEGACY_XTS" >&2
    exit 1
fi

# Pick a timeout binary: BSD's bare `timeout` doesn't exist on
# Darwin out of the box; `gtimeout` (coreutils) is the usual
# workaround. Fall back to a background-and-kill shim if neither
# is present.
if command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_CMD="gtimeout"
elif command -v timeout >/dev/null 2>&1; then
    TIMEOUT_CMD="timeout"
else
    TIMEOUT_CMD=""
fi

run_with_timeout() {
    if [[ -n "$TIMEOUT_CMD" ]]; then
        "$TIMEOUT_CMD" "$TIMEOUT" "$@"
    else
        "$@" &
        local pid=$!
        ( sleep "$TIMEOUT" && kill -9 "$pid" 2>/dev/null ) &
        local watchdog=$!
        wait "$pid" 2>/dev/null
        local rc=$?
        kill -9 "$watchdog" 2>/dev/null
        return $rc
    fi
}

> "$UNORACLE"
ok=0
skipped=0
total=0

for src in "$FIXTURE_DIR"/*.xc; do
    name="$(basename "$src" .xc)"
    total=$((total + 1))
    xex="$TMPDIR/$name.xex"
    log="$TMPDIR/$name.compile.log"
    out="$FIXTURE_DIR/$name.expected.out"

    # Compile via legacy AST codegen.
    if ! "$LEGACY_XTC" -m xl "$src" -o "$xex" \
            > "$log" 2>&1; then
        first_err="$(grep -E 'error|Error|ERROR' "$log" | head -1)"
        [[ -z "$first_err" ]] && first_err="$(tail -1 "$log")"
        echo "$name: $first_err" >> "$UNORACLE"
        skipped=$((skipped + 1))
        rm -f "$out"
        continue
    fi

    # Simulate, capture stdout.
    if ! run_with_timeout "$LEGACY_XTS" -d "$xex" > "$out" 2>/dev/null; then
        echo "$name: xts failed or timed out" >> "$UNORACLE"
        skipped=$((skipped + 1))
        rm -f "$out"
        continue
    fi
    ok=$((ok + 1))
done

echo "generated $ok oracle(s); skipped $skipped of $total fixtures"
echo "unoracleable list: $UNORACLE"
