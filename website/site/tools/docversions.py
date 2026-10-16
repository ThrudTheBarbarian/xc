#!/usr/bin/env python3
"""docversions.py — versioned documentation trees for the site.

Each public release has its own tree under src/content/docs/versions/<ver>/,
made from the docs as they stood at the release's tag, and the default tree is
always the current documentation. No tree says "from 0.72" or "(new in 0.8)":
a tree documents one version, so it describes what that version does, and a
feature a version lacks is simply absent from its tree.

    python3 tools/docversions.py strip            # remove version markers from the current tree
    python3 tools/docversions.py strip --check    # list what is left (exit 1 if any)
    python3 tools/docversions.py snapshot v0.8    # (re)build versions/0.8 from the tag
    python3 tools/docversions.py snapshot --all   # every v* tag

At a release: snapshot the new tag, so the release's own tree is kept when the
current docs move on.
"""
import os, re, subprocess, sys

SITE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOCS = os.path.join(SITE, 'src', 'content', 'docs')
REPO = subprocess.run(['git', '-C', SITE, 'rev-parse', '--show-toplevel'], capture_output=True, text=True).stdout.strip()
DOCS_IN_REPO = os.path.relpath(DOCS, REPO)

# Pages that are about every release rather than one: never versioned, and
# their version numbers are content, not markers.
UNVERSIONED = ('index.mdx', 'feedback.mdx', 'compiler/performance', 'compiler/benchmarks', 'compiler/downloads',
               'compiler/future-work', 'versions/')

V = r'(\d+\.\d+(?:\.\d+)?)(?!\.?\d)'


def ver(s):
    """'0.8' < '0.75'? No: release numbers read as decimals, 0.8 is 0.80."""
    p = s.split('.')
    major, minor = int(p[0]), p[1]
    minor = int(minor) * (10 if len(minor) == 1 else 1)
    return (major, minor, int(p[2]) if len(p) > 2 else 0)


def unversioned(rel):
    return any(rel == u or rel.startswith(u) for u in UNVERSIONED)


def up(c, rest=''):
    """Capitalise a sentence's first word, but not a name like macOS or iOS."""
    if not c.isalpha() or any(ch.isupper() for ch in rest[:12].split(' ')[0]):
        return c
    return c.upper()


def strip(text, tree=None):
    """Remove version markers. tree: the version this tree documents (a ver()
    tuple), or None for the current tree; a marker naming a later version
    takes its paragraph, list item or table row with it."""
    later = lambda w: tree is not None and ver(w) > tree
    lines = text.split('\n')
    out = []
    i = 0
    # Paragraph-level removal for a later version's bold marker.
    while i < len(lines):
        ln = lines[i]
        m = re.search(r'\*\*(?:From|Since|New in) ' + V + r'\.?\*\*', ln)
        if m and later(m.group(1)):
            # Drop this paragraph: back to the last blank line, on to the next.
            while out and out[-1].strip():
                out.pop()
            while i < len(lines) and lines[i].strip():
                i += 1
            continue
        m = re.search(r'\((?:from|since|new in) ' + V + r'[^)]*\)', ln, re.I)
        if m and later(m.group(1)) and (ln.lstrip().startswith(('-', '*', '|')) or re.match(r'\s*\d+\.', ln)):
            i += 1
            continue
        out.append(ln)
        i += 1
    t = '\n'.join(out)
    # A line that is nothing but a marker.
    t = re.sub(r'(?m)^[ \t]*(?:\*\*)?(?:From|Since|New in) ' + V + r'\.?(?:\*\*)?\.?[ \t]*\n', '', t)
    # **From 0.72.** at the end of a paragraph or on a line of its own.
    t = re.sub(r'[ \t]*\*\*(?:From|Since|New in) ' + V + r'\.\*\*', '', t)
    # **From 0.8.1** the compiler … — the marker opens the sentence.
    t = re.sub(r'\*\*(?:From|Since|New in) ' + V + r'\*\*,?[ \t]+(\S)(\S*)', lambda m: up(m.group(2), m.group(3)) + m.group(3), t)
    # *(0.4)* on a line of its own (an old API page's mark), and (xcc 0.4).
    t = re.sub(r'(?m)^[ \t]*\*\(' + V + r'\)\*[ \t]*\n', '', t)
    t = re.sub(r'[ \t]*\((?:xcc|xtc) ' + V + r'\)', '', t)
    # (from 0.7), (since 0.73), (new in 0.8).
    t = re.sub(r'[ \t]*\((?:from|since|new in) ' + V + r'\)', '', t, flags=re.I)
    # From 0.74, `xcc -g` writes … — at a line's or a sentence's start.
    t = re.sub(r'(^|(?<=[.!?:]\s)|(?<=^[-*] )|(?<=\| ))From ' + V + r',?[ \t\n]+(\S)(\S*)',
               lambda m: m.group(1) + up(m.group(3), m.group(4)) + m.group(4), t, flags=re.M)
    # … then the key. From 0.7.  — a closing sentence that is only a marker.
    t = re.sub(r'[ \t]+(?:\*\*)?From\s+' + V + r'\.(?:\*\*)?(?=[ \t]*(?:$|\|))', '', t, flags=re.M)
    # From 0.8.1: the default goal …  /  **From 0.66, the default**
    t = re.sub(r'(^|(?<=\| )|(?<=\*\*))From ' + V + r'[:,][ \t]+(\S)(\S*)',
               lambda m: m.group(1) + up(m.group(3), m.group(4)) + m.group(4), t, flags=re.M)
    # - from 0.73, the user's own … — a list item that opens with it.
    t = re.sub(r'(?m)^([ \t]*[-*] )from ' + V + r',?[ \t]+', r'\1', t)
    # every backend, from 0.7.  →  every backend.
    t = re.sub(r',[ \t]+from ' + V + r'(?=[.;:)])', '', t)
    # …, from 0.72, … and … the worker from 0.75.
    t = re.sub(r',[ \t]+from ' + V + r',', ',', t)
    t = re.sub(r'[ \t]+from ' + V + r'(?=[.;,:)])', '', t)
    # The history prose no pattern can rewrite (docfixes.py).
    import docfixes
    t = docfixes.apply(t)
    # Tidy: a paragraph left empty, runs of blank lines.
    t = re.sub(r'\n{3,}', '\n\n', t)
    return t


# What the check reports: a version after a word that dates something, on one
# line or wrapped onto the next. (`up to 999.99 ms` is no version: two digits
# at most after the point, and not followed by more digits.)
LEFT = re.compile(r'(?i)(?:\b(?:from|since|new in|added in|as of|before|until|up to|in|of)\s+(?:xcc\s+|version\s+)?v?|\((?:xcc |xtc )|\*\()\b[0-9]\.\d{1,2}(?:\.\d+)?\b(?!\.\d)')


def leftovers(text):
    out = []
    lines = text.split('\n')
    for m in LEFT.finditer(text):
        n = text.count('\n', 0, m.start()) + 1
        out.append((n, ' '.join(m.group(0).split()), lines[n - 1].strip()[:160]))
    return out


def walk(root):
    for d, _, fs in os.walk(root):
        for f in fs:
            if f.endswith(('.md', '.mdx')):
                p = os.path.join(d, f)
                yield p, os.path.relpath(p, root)


def cmd_strip(check):
    left = 0
    for p, rel in walk(DOCS):
        if unversioned(rel):
            continue
        t = open(p).read()
        s = strip(t)
        if s != t and not check:
            open(p, 'w').write(s)
        for n, w, ln in leftovers(s):
            left += 1
            print(f'{rel}:{n}: [{w}] {ln}')
    print(f'--- {left} version mention(s) left in the current tree')
    return 1 if (check and left) else 0


def main():
    a = sys.argv[1:]
    if not a:
        print(__doc__)
        return 2
    if a[0] == 'strip':
        return cmd_strip('--check' in a)
    if a[0] == 'snapshot':
        from docsnapshot import snapshot, all_tags
        tags = all_tags() if '--all' in a else [x for x in a[1:] if not x.startswith('-')]
        for t in tags:
            snapshot(t)
        return 0
    print(__doc__)
    return 2


if __name__ == '__main__':
    sys.exit(main())
