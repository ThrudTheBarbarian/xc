#!/usr/bin/env python3
"""Test the claim that the undocumented remainder is all internal.

"Internal" is not a feeling — it is a measurable property: nothing outside the
class's own file calls it. So take every method check_coverage.py still reports
and look for a call site elsewhere: another framework file, a doc example, or
the Rocks application.

Anything with an outside caller is app-facing and the claim is wrong about it.
"""
import os, re, sys

XC_ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
sys.path.insert(0, os.path.join(XC_ROOT, "website", "site"))
import check_coverage as C
CALLERS = [
    os.path.join(XC_ROOT, "frameworks/uxkit"),
    os.path.join(XC_ROOT, "website/site/examples/uxkit"),
    os.path.join(XC_ROOT, "apps/rocks/xc"),
]

def collect(paths):
    out = {}
    for root in paths:
        if not os.path.isdir(root):
            continue
        for dirpath, _d, files in os.walk(root):
            for fn in files:
                if fn.endswith(".xc"):
                    p = os.path.join(dirpath, fn)
                    out[p] = open(p, errors="ignore").read()
    return out

def main():
    files = collect(CALLERS)

    # Re-derive the undocumented set exactly as check_coverage does.
    srcs = {}
    for fn in sorted(os.listdir(C.SRC)):
        if fn.endswith(".xc") and not fn.startswith("test_"):
            srcs[fn] = open(os.path.join(C.SRC, fn), errors="ignore").read()
    srcs_all = "\n".join(srcs.values())

    # How many DISTINCT classes declare each method name? A name that several
    # siblings declare (every driver has structGrow, hitOne, drawOne) cannot be
    # attributed by a textual call site, so it is not evidence of anything.
    decl_count = {}
    for text in srcs.values():
        for m in re.finditer(r'^\s{4}(?:static\s+)?[\w<>\*]+\s*\*?\s+([a-z][A-Za-z0-9_]*)\s*\(', text, re.M):
            decl_count.setdefault(m.group(1), set()).add(id(text))

    external = []
    for page in sorted(os.listdir(C.DOCS)):
        if not (page.endswith(".md") or page.endswith(".mdx")):
            continue
        stem = page.rsplit(".", 1)[0]
        if stem.startswith("guide-") or stem == "index":
            continue
        cls = body = home = None
        for sf, text in srcs.items():
            for m in re.finditer(r'^(?:class|protocol)\s+(UX[A-Za-z0-9]+)', text, re.M):
                if m.group(1).lower() == stem:
                    cls, body, home = m.group(1), C.class_body(text, m.group(1)), sf
                    break
            if cls and sf.rsplit(".", 1)[0].lower() == stem:
                break
        if not body:
            continue

        have = C.documented_names(open(os.path.join(C.DOCS, page), errors="ignore").read())
        for proto in re.findall(r'^(?:class|protocol)\s+%s\b[^{]*<([^>]*)>' %
                                re.escape(cls), srcs_all, re.M):
            for pn in [p.strip() for p in proto.split(",")]:
                for ext in (".md", ".mdx"):
                    pp = os.path.join(C.DOCS, pn.lower() + ext)
                    if os.path.exists(pp):
                        have |= C.documented_names(open(pp, errors="ignore").read())

        homepath = os.path.join(C.SRC, home)
        for line in body.splitlines():
            m = C.METHOD.match(line)
            if not m:
                continue
            name = m.group(1)
            if (name in C.SKIP or name in C.SKIP_HELPERS or name in have
                    or C.NATIVE_SEAM.match(name)):
                continue
            if cls in C.ENTRY_POINT_ONLY and name not in C.ENTRY_POINT_ONLY[cls]:
                continue
            if len(decl_count.get(name, ())) != 1:
                continue          # ambiguous across siblings; cannot attribute
            # A call from OUTSIDE the defining file: `.name(` or `Class.name(`
            pat = re.compile(r'[\.\)]\s*' + re.escape(name) + r'\s*\(')
            for path, text in files.items():
                if os.path.abspath(path) == os.path.abspath(homepath):
                    continue
                base = os.path.basename(path)
                if base.startswith("test_") or base.startswith("demo_") or base.startswith("ks_"):
                    continue      # tests reach inside on purpose
                if pat.search(text):
                    external.append((page, cls, name, os.path.relpath(path, XC_ROOT)))
                    break

    for page, cls, name, where in external:
        print("  EXTERNAL  %-26s %s.%s()  called from %s" % (page, cls, name, where))
    print("== audit: %d undocumented method(s) have a caller outside their own file ==" %
          len(external))

if __name__ == "__main__":
    main()
