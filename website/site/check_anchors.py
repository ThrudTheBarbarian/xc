#!/usr/bin/env python3
"""check_anchors.py — every #fragment in the docs points at a real heading.

check_links.py deliberately strips the fragment and checks only the page, so
an anchor has never been verified by anything. These pages are dense with them:
a Topics line is a dozen `[name](#name)` links, and the prose cross-references
sections constantly. A heading renamed once silently breaks every link to it,
and the Astro build does not care.

Slugs follow github-slugger, which is what Starlight uses: lowercase, drop
everything that is not alphanumeric / space / hyphen, then spaces to hyphens.
So `### toLower / toUpper` is `tolower--toupper` — two hyphens, because the
slash vanishes and both spaces become hyphens.
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
DOCS = os.path.join(HERE, "src/content/docs")

def slug(heading):
    s = heading.strip().lower()
    s = s.replace("`", "")
    # inline links in a heading contribute their TEXT only
    s = re.sub(r'\[([^\]]*)\]\([^)]*\)', r'\1', s)
    s = re.sub(r'[^\w \-]', '', s, flags=re.U)
    return s.replace(" ", "-")

def headings(text):
    out = set()
    # fenced code can contain lines starting with #; skip fences.
    infence = False
    for line in text.splitlines():
        if line.lstrip().startswith("```"):
            infence = not infence
            continue
        if infence:
            continue
        m = re.match(r'^(#{2,6})\s+(.+?)\s*$', line)
        if m:
            h = m.group(2)
            # Starlight asides: `:::note[Title]` also become headings? No — but
            # a heading may carry trailing markup; slug() normalises it.
            out.add(slug(h))
    return out

def page_key(path):
    """/compiler/api/uxkit/uxtext  <- src/content/docs/compiler/api/uxkit/uxtext.md"""
    rel = os.path.relpath(path, DOCS)
    rel = rel.rsplit(".", 1)[0]
    return "/" + rel.replace(os.sep, "/")

def main():
    pages = {}
    for root, _dirs, files in os.walk(DOCS):
        for fn in files:
            if fn.endswith(".md") or fn.endswith(".mdx"):
                p = os.path.join(root, fn)
                pages[page_key(p)] = (p, open(p, errors="ignore").read())

    anchors = {k: headings(t) for k, (_p, t) in pages.items()}

    problems, checked = [], 0
    for key, (path, text) in sorted(pages.items()):
        rel = os.path.relpath(path, DOCS)
        # same-page:  ](#frag)
        for frag in re.findall(r'\]\(#([^)\s]+)\)', text):
            checked += 1
            if frag not in anchors[key]:
                problems.append((rel, "#" + frag, "this page"))
        # cross-page: ](/some/page/#frag)
        for target, frag in re.findall(r'\]\((/[^)#\s]*)#([^)\s]+)\)', text):
            t = target.rstrip("/")
            if t not in anchors:
                continue          # a missing PAGE is check_links.py's job
            checked += 1
            if frag not in anchors[t]:
                problems.append((rel, "#" + frag, t))

    for rel, frag, where in problems:
        print("  DEAD  %s -> %s (no such heading in %s)" % (rel, frag, where))
    print("== anchors: %d checked, %d dead ==" % (checked, len(problems)))
    return 1 if problems else 0

if __name__ == "__main__":
    sys.exit(main())
