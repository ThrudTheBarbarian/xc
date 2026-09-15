#!/bin/bash
# check-wasm-loader.sh — the wasm .js loader exists TWICE and must not drift.
#
# The reference embeds it as a 269-line string literal in
# src/xtcln-wasm32/main.m; the xc driver reads
# support/wasm32/runtime/loader.js.in, which was extracted from it. Two copies
# of anything in this tree is how the float stride (073) and the allocator
# contract (027) went wrong, so this re-extracts and compares.
#
# It is not a differential of COMPILER OUTPUT — both drivers emit byte-identical
# loaders today, verified by building the same program with each. It guards the
# SOURCE, so an edit to one copy cannot silently leave the other behind.
set -u
cd "$(dirname "$0")/.." || exit 1
REF=src/xtcln-wasm32/main.m
TMPL=support/wasm32/runtime/loader.js.in
[ -f "$REF" ]  || { echo "check-wasm-loader: $REF missing"; exit 1; }
[ -f "$TMPL" ] || { echo "check-wasm-loader: $TMPL missing"; exit 1; }

python3 - "$REF" "$TMPL" <<'PY'
import re, sys
ref, tmpl = sys.argv[1], sys.argv[2]
src = open(ref, encoding='utf-8').read()
start = src.index('static NSString *loaderJS(')
end   = src.index('    t = [t stringByReplacingOccurrencesOfString:@"__BASE__"', start)
lines = re.findall(r'^"((?:[^"\\]|\\.)*)"\s*;?\s*$', src[start:end], re.M)
ESC = {'n':'\n','t':'\t','r':'\r','"':'"','\\':'\\','0':'\0'}
want = re.sub(r'\\(.)', lambda m: ESC.get(m.group(1), '\\' + m.group(1)), ''.join(lines))
have = open(tmpl, encoding='utf-8').read()
if want == have:
    print("check-wasm-loader: OK (%d lines, both copies agree)" % len(have.split('\n')))
    sys.exit(0)
print("check-wasm-loader: THE TWO LOADER COPIES HAVE DRIFTED")
print("  reference: %s (%d lines)" % (ref, len(want.split('\n'))))
print("  template:  %s (%d lines)" % (tmpl, len(have.split('\n'))))
import difflib
for d in list(difflib.unified_diff(want.split('\n'), have.split('\n'),
                                   'reference', 'template', lineterm=''))[:20]:
    print("   ", d)
sys.exit(1)
PY
