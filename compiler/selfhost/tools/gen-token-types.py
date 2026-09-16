#!/usr/bin/env python3
"""Generate selfhost/lexer/TokenType.xc from src/xtc/lexer/XTTokenType.h.

The two lexers — the Objective-C one in src/xtc/lexer and the xtc one in
selfhost/lexer — dump their token streams in the same format and are compared
byte for byte (selfhost/tools/lexer-diff.sh). The NUMERIC token type is part of
that comparison, so the xtc enum has to carry the same values as the ObjC one,
including the "appended to avoid renumbering" tail.

Transcribing 115 enumerators by hand is exactly the kind of thing that is wrong
in one place and stays wrong for months, so it is generated. Run this after
appending to XTTokenType.h:

    python3 selfhost/tools/gen-token-types.py

Output is checked in — the build does not depend on Python.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HEADER = ROOT / "src/xtc/lexer/XTTokenType.h"
OUT = ROOT / "selfhost/lexer/TokenType.xc"

text = HEADER.read_text()

# The enum body: from `typedef NS_ENUM(NSInteger, XTTokenType) {` to the
# matching `};`.
m = re.search(r"typedef NS_ENUM\(NSInteger, XTTokenType\)\s*\{(.*?)\n\};", text, re.S)
if not m:
    sys.exit("gen-token-types: could not find the XTTokenType enum body")

body = m.group(1)
names = []
for line in body.splitlines():
    line = re.sub(r"//.*$", "", line).strip()
    if not line:
        continue
    for mm in re.finditer(r"\bXTToken([A-Za-z0-9_]+)\s*(?:=\s*[^,]+)?,", line):
        names.append(mm.group(1))

if not names:
    sys.exit("gen-token-types: no enumerators found")

lines = [
    "// TokenType.xc — the token kinds, numbered exactly as XTTokenType is.",
    "// =================================================================",
    "//",
    "// GENERATED from src/xtc/lexer/XTTokenType.h by",
    "// selfhost/tools/gen-token-types.py. Do not edit by hand: the numbers are a",
    "// CONTRACT between the two lexers, whose token dumps are compared byte for",
    "// byte, and a hand-transcribed copy of 115 enumerators is wrong in one place",
    "// for months before anyone notices.",
    "//",
    "// Append-only, like the Objective-C enum it mirrors: inserting in the middle",
    "// renumbers every later token and breaks separately-compiled objects.",
    "",
    "enum TokenType = {",
]
width = max(len(n) for n in names) + 1
for i, n in enumerate(names):
    comma = "," if i + 1 < len(names) else ""
    lines.append("    tok%-*s = %d%s" % (width, n, i, comma))
lines.append("};")
lines.append("")
lines.append("// The count, for a bounds check on a dumped stream.")
lines.append("#define TOKEN_TYPE_COUNT %d" % len(names))
lines.append("")

# The NAMES too — XTTokenTypeName's switch, so a diagnostic can say
# `unexpected ';'` instead of `unexpected token 11 (wanted 85)` (task #78).
# Generated for the same reason the numbers are: a hand copy drifts.
# Anchored on the signature, not on where the braces sit: the cases are spelled
# this way only inside XTTokenTypeName, so reading to the end of the header is
# safe and does not depend on the layout of the switch.
nm = re.search(r"XTTokenTypeName\s*\(\s*XTTokenType\s+type\s*\)", text)
if not nm:
    sys.exit("gen-token-types: could not find the XTTokenTypeName switch")
pairs = re.findall(r'case XTToken([A-Za-z0-9_]+):\s*return @"((?:[^"\\\\]|\\\\.)*)";', text[nm.end():])
if not pairs:
    sys.exit("gen-token-types: no names found in XTTokenTypeName")
known = set(names)
for n, _ in pairs:
    if n not in known:
        sys.exit("gen-token-types: XTTokenTypeName names %s, which is not in the enum" % n)
lines.append("// The human name of each token kind, as XTTokenTypeName spells it — for")
lines.append("// diagnostics only. A kind the reference does not name comes back as `?`.")
lines.append("class TokenNames")
lines.append("{")
lines.append("    u8 _unused;")
lines.append("    void init(void) { _unused = (u8)0; }")
lines.append("    static string of(u16 t)")
lines.append("    {")
for n, text_name in pairs:
    lines.append('        if (t == (u16)tok%s) return "%s";' % (n, text_name))
lines.append('        return "?";')
lines.append("    }")
lines.append("}")
lines.append("")

OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text("\n".join(lines))
print("gen-token-types: %d token types -> %s" % (len(names), OUT.relative_to(ROOT)))
