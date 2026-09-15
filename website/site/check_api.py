#!/usr/bin/env python3
"""check_api.py — every method signature a UXKit doc page shows must exist.

The docs are written by reading source, and reading is where invented API comes
from: this pass has already shipped `slider.value()` and `selectItemWithTag`,
neither of which existed. The compiler caught those two because they were in
compiled examples. A signature quoted in prose has nothing checking it.

So: pull every `<type> <name>(...)` declaration out of each page's ```c fences,
find the class the page documents, and assert the source declares that name.

Deliberately NAME-ONLY. Matching parameter lists would need a parser and would
fail on the doc's own reformatting (line breaks, comments); the name is what a
reader types, and a name that does not exist is the error worth catching.
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
DOCS = os.path.join(HERE, "src/content/docs/compiler/api/uxkit")
SRC  = os.path.abspath(os.path.join(HERE, "../../frameworks/uxkit"))

# Words that appear in a `<type> <name>(` position but are not methods.
NOT_A_METHOD = {
    "if", "while", "for", "return", "switch", "sizeof", "new", "delete",
    "printf", "class", "protocol", "struct", "typedef", "defined",
}

# A declaration line: optional `static`/`optional`, a type (with * / <>), a
# name, then '('. Excludes calls, because a call has a receiver before it.
DECL = re.compile(
    r'^\s*(?:static\s+|optional\s+)?'          # leading qualifier
    r'(?:callback\s+\w+\s+)?'                  # `callback cb void(...)` form
    r'[A-Za-z_][\w]*\s*(?:<[^>]*>)?\s*\*?\s+'  # the return type
    r'([a-z][A-Za-z0-9_]*)\s*\('               # the NAME (methods are lowerCamel)
)

def source_for(page_stem):
    """The .xc file declaring the class this page documents, or None.

    Tests declare stand-in classes with real names — test_win32.xc has its own
    `class UXView` — so a plain first-match scan attributes the page to the
    wrong file and then reports the entire real API as missing. Skip test_*,
    and prefer the file named after the class when there is one.
    """
    want = page_stem.lower()
    candidates = []
    for fn in sorted(os.listdir(SRC)):
        if not fn.endswith(".xc") or fn.startswith("test_"):
            continue
        path = os.path.join(SRC, fn)
        try:
            text = open(path, errors="ignore").read()
        except OSError:
            continue
        for m in re.finditer(r'^(?:class|protocol)\s+(UX[A-Za-z0-9]+)', text, re.M):
            if m.group(1).lower() == want:
                # UXColorPanel declared in UXColorPanel.xc wins over any other.
                exact = fn.rsplit(".", 1)[0].lower() == want
                candidates.append((0 if exact else 1, path, text))
                break
    if not candidates:
        return None
    candidates.sort(key=lambda c: c[0])
    return candidates[0][1], candidates[0][2]

def fences(text):
    """The contents of every ```c fenced block."""
    return re.findall(r'```c\n(.*?)```', text, re.S)

def main():
    problems, checked, pages = [], 0, 0
    for fn in sorted(os.listdir(DOCS)):
        if not (fn.endswith(".md") or fn.endswith(".mdx")):
            continue
        stem = fn.rsplit(".", 1)[0]
        if stem.startswith("guide-") or stem == "index":
            continue
        found = source_for(stem)
        if not found:
            continue                      # covered by the coverage audit, not here
        srcpath, srctext = found
        pages += 1
        page = open(os.path.join(DOCS, fn), errors="ignore").read()

        # Only names the page CLAIMS as API — i.e. ones it gives a `###`
        # reference heading to. A snippet showing the reader's own handler
        # (`void onTab(UXControl* c)`) is a signature THEY write, not one the
        # framework declares, and has no heading.
        claimed = set()
        for h in re.findall(r'^###\s+(.+?)\s*$', page, re.M):
            for part in re.split(r'\s*/\s*', h):
                part = part.strip().strip('`')
                if re.fullmatch(r'[a-z][A-Za-z0-9_]*', part):
                    claimed.add(part)

        names = set()
        for block in fences(page):
            for line in block.splitlines():
                if "=" in line.split("(")[0]:     # an assignment, not a decl
                    continue
                m = DECL.match(line)
                if m:
                    names.add(m.group(1))

        for name in sorted(names & claimed):
            if name in NOT_A_METHOD:
                continue
            checked += 1
            # The source declares it if the identifier is followed by '(' anywhere.
            if not re.search(r'\b' + re.escape(name) + r'\s*\(', srctext):
                problems.append((fn, name, os.path.basename(srcpath)))

    for fn, name, src in problems:
        print("  MISSING  %s: %s() is not declared in %s" % (fn, name, src))
    print("== api: %d signature(s) across %d page(s), %d missing ==" %
          (checked, pages, len(problems)))
    return 1 if problems else 0

if __name__ == "__main__":
    sys.exit(main())
