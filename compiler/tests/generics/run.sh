#!/bin/bash
# Typed collections (stage D). Runs the fixture at every -O level and checks
# that the element type is ENFORCED, not merely applied — the differentials
# compare the two compilers on it, but neither of them runs it.
set -u
cd "$(dirname "$0")/../.." || exit 1
BIN=bin/osx; [ -d "$BIN" ] || BIN=bin/linux
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail=0

for O in 0 1 2 3; do
    if ! "$BIN/xcc" -O$O -A arm64 -H . -o "$TMP/t" tests/generics/typed_collections.xc \
            > "$TMP/build.log" 2>&1; then
        echo "  FAIL -O$O: compile"; sed 's/^/    /' "$TMP/build.log"; fail=1; continue
    fi
    if diff -q <("$TMP/t") tests/generics/expected.out >/dev/null 2>&1; then
        echo "  PASS -O$O"
    else
        echo "  FAIL -O$O: output"; diff <("$TMP/t") tests/generics/expected.out | sed 's/^/    /'; fail=1
    fi
done

# The element type must be ENFORCED, not merely applied: a wrong insert is an
# error, and a primitive element type is rejected rather than silently ignored.
neg() {
    printf '%s\n' "$2" > "$TMP/neg.xc"
    if "$BIN/xcc" -A arm64 -H . -o "$TMP/neg" "$TMP/neg.xc" 2>&1 | grep -q "$3"; then
        echo "  PASS reject: $1"
    else
        echo "  FAIL reject: $1 (expected /$3/)"; fail=1
    fi
}
neg "wrong element type" '#import "String.xc"
#import "Array.xc"
#import "Number.xc"
i32 main(void) { Array<String>* a = new Array(); a.add(Number.withU32((u32)7)); return 0; }' \
    "is not a subclass of"
neg "float into Array<i32>" '#import "Array.xc"
#import "Number.xc"
i32 main(void) { Array<i32>* a = new Array(); a.add((float)1.5); return 0; }' \
    "cannot be stored in a collection of"
neg "int into Array<float>" '#import "Array.xc"
#import "Number.xc"
i32 main(void) { Array<float>* a = new Array(); a.add((i32)3); return 0; }' \
    "cannot be stored in a collection of"

[ $fail = 0 ] && echo "typed-collections: all pass" || echo "typed-collections: FAILURES"
exit $fail
