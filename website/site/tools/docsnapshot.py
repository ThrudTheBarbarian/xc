"""docsnapshot.py — one release's documentation tree, from its tag.

Used by docversions.py. The tree is the docs as they stood at the tag, with
the version markers taken out (docversions.strip, told which version the tree
documents), internal links pointed at the same tree, and each page marked as
an older version's: a banner naming it and linking to the current docs, and
no entry in the site search (which should find the current docs).
"""
import os, re, shutil, subprocess
import docversions as dv


def all_tags():
    out = subprocess.run(['git', '-C', dv.REPO, 'tag', '--list', 'v*'], capture_output=True, text=True).stdout.split()
    return sorted(out, key=lambda t: dv.ver(t[1:]))


def label(tag):
    return tag[1:]


def show(tag, path):
    return subprocess.run(['git', '-C', dv.REPO, 'show', f'{tag}:{path}'], capture_output=True, text=True, check=True).stdout


def pages_at(tag):
    out = subprocess.run(['git', '-C', dv.REPO, 'ls-tree', '-r', '--name-only', tag, '--', dv.DOCS_IN_REPO],
                         capture_output=True, text=True, check=True).stdout.split()
    pages = {}
    for p in out:
        if not p.endswith(('.md', '.mdx')):
            continue
        rel = os.path.relpath(p, dv.DOCS_IN_REPO)
        if dv.unversioned(rel):
            continue
        pages[rel] = p
    return pages


def slug_of(rel):
    s = re.sub(r'\.mdx?$', '', rel)
    s = re.sub(r'(^|/)index$', '', s)
    return s


def frontmatter(text, banner, slug):
    """Add the banner, the page's slug (Astro would make "0.8" into "08"), and
    keep the page out of the search."""
    extra = f"slug: {slug}\nbanner:\n  content: '{banner}'\npagefind: false\n"
    if text.startswith('---\n'):
        end = text.index('\n---', 4)
        head = text[4:end]
        head = re.sub(r'(?m)^(banner:.*\n(?:[ \t]+.*\n)*|pagefind:.*\n|slug:.*\n)', '', head + '\n').rstrip('\n')
        return '---\n' + head + '\n' + extra + text[end + 1:]
    return '---\n' + extra + '---\n' + text


def snapshot(tag):
    v = label(tag)
    tree = dv.ver(v)
    dest = os.path.join(dv.DOCS, 'versions', v)
    if os.path.isdir(dest):
        shutil.rmtree(dest)
    pages = pages_at(tag)
    slugs = {slug_of(rel) for rel in pages}
    banner = (f'This is the documentation for xc {v}. '
              f'<a href="/compiler/">The current documentation</a> describes the newest version.')
    link = re.compile(r'(\]\(|href=")/([a-z0-9][a-z0-9/_\-]*?)/?(#[^)"]*)?(\)|")')

    def relink(m):
        target = m.group(2).rstrip('/')
        if target in slugs:
            return f'{m.group(1)}/versions/{v}/{target}/{m.group(3) or ""}{m.group(4)}'
        return m.group(0)

    left = []
    for rel, path in sorted(pages.items()):
        text = show(tag, path)
        text = dv.strip(text, tree)
        text = link.sub(relink, text)
        text = frontmatter(text, banner, f'versions/{v}/{slug_of(rel)}'.rstrip('/'))
        out = os.path.join(dest, rel)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        open(out, 'w').write(text)
        for n, w, ln in dv.leftovers(text):
            left.append(f'versions/{v}/{rel}:{n}: [{w}] {ln}')
    print(f'{v}: {len(pages)} pages, {len(left)} version mention(s) left')
    for l in left:
        print('   ', l)
    return left
