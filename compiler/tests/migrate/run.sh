#!/bin/bash
# tests/migrate/run.sh — uxkit/025: `--migrate=<base>:<to>` scoping.
#
# The flag hides members marked `since("<to>")` so that a program written
# against <base> fails LOUDLY on the two names whose meaning silently changed
# (String.charAt, String.appendChar) instead of compiling to different
# behaviour. The hiding must apply to the PROGRAM being migrated and not to the
# standard library, which ships with this compiler and is already written
# against <to>.
#
# It used to apply to both, which made the flag unusable by anything: Url.xc
# arrives through the implicit prelude, so EVERY --migrate build died inside the
# stdlib before reaching a line of user code. A driver flag cannot be tested
# from a corpus fixture, so it is pinned here.
set -u
cd "$(dirname "$0")/../.." || exit 1
BIN=bin/osx; [ -x "$BIN/xcc" ] || BIN=bin/linux
WORK=${TMPDIR:-/tmp}/migrate.$$
mkdir -p "$WORK"; trap 'rm -rf "$WORK"' EXIT
fail=0

# T1 — a program that reaches the migrated stdlib must BUILD and RUN. It does
# not import Url: the point is that the prelude pulls it in regardless, which is
# why this failed for every program and not only for Url's clients.
cat > "$WORK/pos.xc" <<'EOF'
#import "Stdio.xc"
void main(void) { Stdio.printf("ok\n"); }
EOF
if "$BIN/xcc" -H . -q --migrate=0.3:0.4 -A arm64 -o "$WORK/pos" "$WORK/pos.xc" >"$WORK/log" 2>&1 \
   && [ "$("$WORK/pos" 2>/dev/null)" = "ok" ]; then
    echo "  PASS migrate: the stdlib is exempt (a --migrate build completes)"
else
    echo "  FAIL migrate: --migrate build broken by the stdlib's own sources"
    sed 's/^/    /' "$WORK/log" | head -5; fail=1
fi

# T2 — and the gate must still FIRE on the user's own 0.3-era call, in the
# user's own file. A fix that merely silenced T1 would pass it and be useless.
cat > "$WORK/neg.xc" <<'EOF'
#import "Stdio.xc"
void main(void)
{
    String* s = String.withCString("x");
    s.appendChar((u32)65);
    Stdio.printf("%s\n", s.cString());
}
EOF
if "$BIN/xcc" -H . -q --migrate=0.3:0.4 -A arm64 -o "$WORK/neg" "$WORK/neg.xc" >"$WORK/log" 2>&1; then
    echo "  FAIL migrate: 0.3-era appendChar compiled clean — the gate is not firing"; fail=1
elif grep -q 'neg\.xc.*appendChar' "$WORK/log"; then
    echo "  PASS migrate: the gate fires, and points at the USER's call"
else
    echo "  FAIL migrate: refused, but not at the user's appendChar:"
    sed 's/^/    /' "$WORK/log" | head -5; fail=1
fi

# T3 — without the flag, the same 0.3-era call is just a normal build.
if "$BIN/xcc" -H . -q -A arm64 -o "$WORK/plain" "$WORK/neg.xc" >"$WORK/log" 2>&1; then
    echo "  PASS migrate: no flag, no gate"
else
    echo "  FAIL migrate: appendChar rejected WITHOUT --migrate"
    sed 's/^/    /' "$WORK/log" | head -5; fail=1
fi

exit $fail
