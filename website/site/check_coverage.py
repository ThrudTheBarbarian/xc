#!/usr/bin/env python3
"""check_coverage.py — which public methods have no reference section.

check_api.py asks "is everything documented real?". This asks the other half:
"is everything real documented?" — which is what the undocumented-methods task
was actually about, and which nothing has ever measured.

A method counts as documented if its name appears as (or within) a `###`
heading on its class's page. Combined headings count for every name in them,
which is how `### bolded / unbolded` covers both.

Reports rather than fails by default: some methods genuinely are internal
plumbing, and the judgement of which is a human's. Pass --strict to exit 1.
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
DOCS = os.path.join(HERE, "src/content/docs/compiler/api/uxkit")
SRC  = os.path.abspath(os.path.join(HERE, "../../frameworks/uxkit"))

# Never worth a reference section of its own.
SKIP = {
    "init",          # the constructor; covered by the Overview
    "dealloc",
}
# Implementation helpers every class respells; documenting them is noise.
SKIP_HELPERS = {"slen", "streq", "dup", "clamp", "pow10", "toInt", "lower",
                "upper", "isAlnum", "isDigit", "isAlpha", "indexOf", "rdU16",
                "rdU32", "hxd"}

# Classes whose public surface is deliberately ONE entry point, with everything
# else private machinery. Recorded here — with the reason — so the count stops
# reporting a judgement already made as though it were an open gap.
#
#   UXFilePanel   the toolkit file dialog. Its entire external use anywhere in
#                 the toolkit is `new UXFilePanel()` then `run(prompt, dir)`;
#                 the ~40 others are its scroll state, sort and button
#                 handlers. The page says so explicitly.
ENTRY_POINT_ONLY = {"UXFilePanel": {"run"}}

# The driver-facing readback seam. A driver calls `nativeItemCount()` to build
# a native overlay from the neutral model; application code never does. These
# are consistent across every widget, so they are explained once rather than
# restated per control.
NATIVE_SEAM = re.compile(r'^(native[A-Z]|applyNative)')

METHOD = re.compile(
    r'^\s{4}(?:static\s+)?'
    r'(?:callback\s+\w+\s+)?'
    r'[A-Za-z_][\w]*\s*(?:<[^>]*>)?\s*\*?\s+'
    r'([a-z][A-Za-z0-9_]*)\s*\('
)
# The same shape, but in a doc fence, where there is no 4-space indent.
METHOD_IN_DOC = re.compile(
    r'^\s*(?:static\s+|optional\s+)?'
    r'(?:callback\s+\w+\s+)?'
    r'[A-Za-z_][\w]*\s*(?:<[^>]*>)?\s*\*?\s+'
    r'([a-z][A-Za-z0-9_]*)\s*\('
)

def class_body(text, name):
    """The source lines of `class name` / `protocol name`, brace-matched."""
    m = re.search(r'^(?:class|protocol)\s+%s\b' % re.escape(name), text, re.M)
    if not m:
        return None
    i, depth, started, out = m.start(), 0, False, []
    for line in text[i:].splitlines():
        out.append(line)
        depth += line.count("{") - line.count("}")
        if "{" in line:
            started = True
        if started and depth <= 0:
            break
    return "\n".join(out)

def documented_names(page):
    """Names the page covers — by heading OR by showing the signature.

    A grouped reference (UXViewDriver lists all 93 methods under eight `###`
    group headings, in signature blocks) documents every one of them. Counting
    only `###` names would call that page 94-short, which is the opposite of
    the truth.
    """
    names = set()
    for h in re.findall(r'^###\s+(.+?)\s*$', page, re.M):
        h = re.sub(r'\[([^\]]*)\]\([^)]*\)', r'\1', h).replace("`", "")
        for part in re.split(r'\s*/\s*', h):
            part = part.strip()
            if re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', part):
                names.add(part)
    for block in re.findall(r'```c\n(.*?)```', page, re.S):
        for line in block.splitlines():
            m = METHOD_IN_DOC.match(line)
            if m:
                names.add(m.group(1))
    return names

def main():
    strict = "--strict" in sys.argv
    srcs = {}
    for fn in sorted(os.listdir(SRC)):
        if fn.endswith(".xc") and not fn.startswith("test_"):
            srcs[fn] = open(os.path.join(SRC, fn), errors="ignore").read()

    srcs_all = "\n".join(srcs.values())
    rows, total_missing = [], 0
    for fn in sorted(os.listdir(DOCS)):
        if not (fn.endswith(".md") or fn.endswith(".mdx")):
            continue
        stem = fn.rsplit(".", 1)[0]
        if stem.startswith("guide-") or stem == "index":
            continue
        cls = None
        body = None
        for sf, text in srcs.items():
            for m in re.finditer(r'^(?:class|protocol)\s+(UX[A-Za-z0-9]+)', text, re.M):
                if m.group(1).lower() == stem:
                    cls = m.group(1)
                    body = class_body(text, cls)
                    break
            if cls and sf.rsplit(".", 1)[0].lower() == stem:
                break          # the file named after the class wins
        if not body:
            continue

        have = documented_names(open(os.path.join(DOCS, fn), errors="ignore").read())

        # A protocol IMPLEMENTATION does not re-document the protocol. Seven
        # drivers each restating 93 identical method stubs would bury the thing
        # their pages are actually for — how that backend differs — and the
        # contract is documented once, on the protocol's own page.
        for proto in re.findall(r'^(?:class|protocol)\s+%s\b[^{]*<([^>]*)>' %
                                re.escape(cls), srcs_all, re.M):
            for pname in [p.strip() for p in proto.split(",")]:
                ppage = os.path.join(DOCS, pname.lower() + ".md")
                if not os.path.exists(ppage):
                    ppage = os.path.join(DOCS, pname.lower() + ".mdx")
                if os.path.exists(ppage):
                    have |= documented_names(open(ppage, errors="ignore").read())
        missing = []
        for line in body.splitlines():
            m = METHOD.match(line)
            if not m:
                continue
            name = m.group(1)
            if name in SKIP or name in SKIP_HELPERS or name in have:
                continue
            if cls in ENTRY_POINT_ONLY and name not in ENTRY_POINT_ONLY[cls]:
                continue
            if NATIVE_SEAM.match(name):
                continue
            if name not in missing:
                missing.append(name)
        if missing:
            rows.append((len(missing), fn, missing))
            total_missing += len(missing)

    rows.sort(reverse=True)
    for n, fn, missing in rows:
        print("  %-34s %2d: %s" % (fn, n, ", ".join(missing[:8]) +
                                   (" …" if len(missing) > 8 else "")))
    print("== coverage: %d method(s) with no reference section, across %d page(s) ==" %
          (total_missing, len(rows)))
    return 1 if (strict and total_missing) else 0

if __name__ == "__main__":
    sys.exit(main())
