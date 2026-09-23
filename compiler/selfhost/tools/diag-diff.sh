#!/bin/bash
# diag-diff.sh — does the SHIPPED compiler reject what it should?
# ==============================================================
#
# Every other harness compares two compilers on input that BUILDS. None of them
# looks at what happens to input that must not build, and that gap hid
# private:docs/bugs/077: the shipped compiler collected every parser and sema
# diagnostic and threw them away, so `i32 x = ;` compiled silently, exited 0
# and produced a runnable binary.
#
# A compiler that accepts everything passes every build-and-run test there is.
# This is the harness that fails it.
#
#   bash selfhost/tools/diag-diff.sh            # every expect=sema-error fixture
#   bash selfhost/tools/diag-diff.sh member     # just the matching ones
#
# The subjects are the `//xtc-flags: expect=sema-error` fixtures — the corpus
# already asserts the REFERENCE rejects each one — plus a few syntax errors
# built here, since no fixture can hold source that does not parse.
#
# A fixture is a PASS when the shipped compiler exits non-zero AND says
# something. Both halves matter: exiting non-zero silently is a compiler that
# cannot be debugged, and printing while exiting 0 is a build that looks clean.
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
BIN=bin/osx
[ -x "$BIN/xcc" ] || BIN=bin/linux
WORK=$(mktemp -d "${TMPDIR:-/tmp}/diagdiff.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

echo "building the xc driver (selfhost/tools/xcc.xc → native arm64)…"
"$BIN/xcc" -O2 -A arm64 -H . -o "$WORK/xcc-xc" selfhost/tools/xcc.xc \
    -I support/generic/lib -I support/arm64/lib \
    -I selfhost/lexer -I selfhost/preproc -I selfhost/parser -I selfhost/sema \
    -I selfhost/ir -I selfhost/opt -I selfhost/codegen -I selfhost/asm \
    -I selfhost/link -I selfhost/driver > "$WORK/build.log" 2>&1
if [ ! -x "$WORK/xcc-xc" ]; then
    echo "--- diag-diff: BROKEN (the xc driver did not build)"
    sed 's/^/    /' "$WORK/build.log" | head -25
    exit 1
fi

PATTERN=${1:-}

# Source that does not PARSE cannot live in tests/fixtures — the corpus would
# try to build it — so those subjects are written here.
mkdir -p "$WORK/syn"
cat > "$WORK/syn/syn_empty_init.xc" <<'EOF'
#import "Stdio.xc"
i32 main(void) { i32 x = ; return 0; }
EOF
cat > "$WORK/syn/syn_unclosed.xc" <<'EOF'
#import "Stdio.xc"
i32 main(void) { Stdio.printf("hi\n"); return 0;
EOF
cat > "$WORK/syn/syn_bad_type.xc" <<'EOF'
#import "Stdio.xc"
i32 main(void) { nosuchtype v = (i32)1; return 0; }
EOF
# …and input the PREPROCESSOR must reject. Nothing here ever fed it a bad
# `#import`, which is how private:docs/bugs/094 lived: the shipped compiler collected
# preprocessor diagnostics and threw them away, so a missing include printed
# nothing, exited 0 and produced a binary built without the declarations it
# asked for.
cat > "$WORK/syn/syn_missing_import.xc" <<'EOF'
#import "NoSuchFileAnywhere.xc"
i32 main(void) { return 0; }
EOF
cat > "$WORK/syn/syn_missing_library.xc" <<'EOF'
#import <NoSuchLibraryAnywhere>
i32 main(void) { return 0; }
EOF

pass=0; fail=0
declare -a FAILED

check() {
    local f="$1" label="$2"
    [ -n "$PATTERN" ] && case "$label" in *"$PATTERN"*) ;; *) return;; esac
    # A fixture's OWN flags are part of what it tests. string_migrate_03 means
    # nothing without `--migrate=0.3:0.4`: run without it the file is rejected
    # anyway (String.length was renamed in 0.4), so the harness would score a
    # pass while the rule under test never ran.
    local extra=()
    local flagline
    flagline=$(grep -hE '^//[ ]*xtc-flags:' "$f" 2>/dev/null | head -1)
    case "$flagline" in
      *--migrate=*) extra+=("$(printf '%s' "$flagline" | grep -oE '\-\-migrate=[^ ,]+')");;
    esac
    local out rc
    # `${extra[@]}` on an EMPTY array is an unbound-variable error under
    # `set -u` in bash 3.2, which is what macOS ships: the command then failed
    # before the compiler ran and every subject scored "rejected silently".
    out=$("$WORK/xcc-xc" -H "$ROOT" -A arm64 ${extra[@]+"${extra[@]}"} -o "$WORK/out.bin" "$f" 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ]; then
        fail=$((fail+1)); FAILED+=("$label	ACCEPTED (exit 0)")
    elif [ -z "$out" ]; then
        fail=$((fail+1)); FAILED+=("$label	rejected SILENTLY (exit $rc, no message)")
    elif printf '%s' "$out" | grep -qE 'unrecognised option|not implemented in this compiler'; then
        # A fixture whose FLAG the driver refuses is not a fixture whose RULE
        # fired. Counting it as a pass is the hollow-pass shape: the number
        # goes green while the thing being tested was never reached.
        fail=$((fail+1)); FAILED+=("$label	flag not implemented — the RULE was never exercised")
    elif case "$label" in syn_*) true;; *) false;; esac \
         && ! printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g' \
              | grep -qE '^[^:]+(:[^:]+)*:[0-9]+:[0-9]+: (error|warning): '; then
        # A PARSE diagnostic with no line:column is one an editor cannot jump
        # to. The shipped compiler printed `line 4: unexpected token 11 (wanted
        # 85)` until bug 129, and this harness called that a pass. Matched on
        # the text with the colour escapes stripped — the location is printed
        # bold, so the raw bytes never match. Sema fixtures are not held to it
        # (yet): a sema message is positioned only when its node was.
        fail=$((fail+1)); FAILED+=("$label	rejected WITHOUT A POSITION (no file:line:col: in any line)")
    else
        pass=$((pass+1))
    fi
}

for f in "$WORK"/syn/*.xc; do check "$f" "$(basename "$f" .xc)"; done
for f in tests/fixtures/*.xc; do
    grep -q 'expect=sema-error' "$f" || continue
    check "$f" "$(basename "$f" .xc)"
done

if [ ${#FAILED[@]} -gt 0 ]; then
    echo "--- accepted or silent (${#FAILED[@]}):"
    printf '    %s\n' "${FAILED[@]}"
fi
echo "--- diag-diff: pass=$pass fail=$fail ---"
# NOTHING COMPARED is not a pass. An oracle failure — a file the REFERENCE could
# not build — is skipped, so a broken oracle turns the whole sweep into skips
# and the summary reads pass=0 fail=0. Only `fail` was ever checked, so that
# exited 0 and showed as a clean row in all-diff's table; it hid 961 uncompared
# files on ldx86-diff. private:docs/bugs/239.
if [ "$pass" -eq 0 ]; then
    echo "--- $(basename "$0"): NOTHING WAS COMPARED — this is not a pass"
    exit 1
fi
[ "$fail" -eq 0 ]
