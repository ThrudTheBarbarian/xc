#!/usr/bin/env python3
# check_links.py — every internal link in the docs resolves.
#
# A dead internal link is how the missing protocol pages were found: UXNib
# linked UXDesignable and the target did not exist. The Astro build does not
# fail on one, so nothing caught it — and these pages cross-link heavily enough
# that it will happen again.
#
# Two kinds of target:
#   /some/page/            a content page  -> must exist under src/content/docs
#   /downloads/file.tar.gz a served file   -> must exist under ../downloads
import re, os, glob, sys

here = os.path.dirname(os.path.abspath(__file__))
root = os.path.join(here, "src", "content", "docs")
dls  = os.path.join(here, "..", "downloads")

slugs = set()
for p in glob.glob(root + "/**/*.md", recursive=True) + glob.glob(root + "/**/*.mdx", recursive=True):
    rel = os.path.relpath(p, root).rsplit(".", 1)[0]
    if rel.endswith("/index"):
        rel = rel[:-6]
    slugs.add("/" + rel.rstrip("/"))

files = set(os.listdir(dls)) if os.path.isdir(dls) else set()
pub   = os.path.join(here, "public")

bad = {}
for p in sorted(glob.glob(root + "/**/*.md", recursive=True) +
                glob.glob(root + "/**/*.mdx", recursive=True)):
    text = open(p, errors="ignore").read()
    for m in re.finditer(r"\]\((/[^)#\s]*)(?:#[^)\s]*)?\)", text):
        t = m.group(1)
        if t.startswith("/downloads/"):
            if os.path.basename(t) not in files:
                bad.setdefault(os.path.relpath(p, root), set()).add(t)
        elif re.search(r"\.(png|jpg|jpeg|svg|webp|gif|zip|pdf)$", t):
            if not os.path.exists(os.path.join(pub, t.lstrip("/"))):
                bad.setdefault(os.path.relpath(p, root), set()).add(t)
        else:
            if t.rstrip("/") not in slugs:
                bad.setdefault(os.path.relpath(p, root), set()).add(t)

# QUARANTINED, reported every run rather than deleted. compiler/downloads/
# historical.md offers the xtc 0.1/0.11/0.12 archives so an existing build can
# be reproduced byte-for-byte against the version it was compiled with — a real
# promise, and the files are not in website/downloads/. Either they need
# uploading or the page should say where they live; both are the site owner's
# call, so this gate names them and does not fail on them.
KNOWN = {t for t in (
    "/downloads/xtc-linux-0.1.tar.bz2",  "/downloads/xtc-osx-0.1.tar.bz2",
    "/downloads/xtc-win64-0.1.zip",
    "/downloads/xtc-linux-0.11.tar.bz2", "/downloads/xtc-osx-0.11.tar.bz2",
    "/downloads/xtc-win64-0.11.zip",
    "/downloads/xtc-linux-0.12.tar.bz2", "/downloads/xtc-osx-0.12.tar.bz2",
    "/downloads/xtc-win64-0.12.zip",
)}

# PENDING: archives the downloads page advertises for the CURRENT release that
# are not in website/downloads/ yet. A different category from the above on
# purpose — a decade-old archive being absent is tolerable, the archive for the
# release you are announcing is not — so these are named individually and
# loudly, and the list going empty is the signal the release is complete.
#
# Empty since the 0.6 archives landed (2026-09-15, verified: three valid
# archives, 329 entries each, top-level dirs matching the install commands).
# Refill it at the next cut, before the files exist.
PENDING = set()

known_hits = 0
pending_hits = set()
for f in list(bad):
    still = {t for t in bad[f] if t not in KNOWN and t not in PENDING}
    pending_hits |= {t for t in bad[f] if t in PENDING}
    known_hits += len({t for t in bad[f] if t in KNOWN})
    if still: bad[f] = still
    else:     del bad[f]

n = sum(len(v) for v in bad.values())
for f, v in sorted(bad.items()):
    for t in sorted(v):
        print(f"  BROKEN  {f} -> {t}")
for t in sorted(pending_hits):
    print(f"  PENDING {t}  (current-release archive, not uploaded yet)")
if pending_hits:
    print(f"== links: {len(pending_hits)} PENDING the 0.6 upload — the downloads page "
          f"promises these ==")
if known_hits:
    print(f"== links: {known_hits} KNOWN-BROKEN (historical download archives, not in website/downloads/) ==")
print(f"== links: {n} broken ==")
sys.exit(1 if n else 0)
