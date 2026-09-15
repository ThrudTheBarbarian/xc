#!/bin/sh
# run_doc_links.sh — the `doc-links` gate: every internal link in the docs resolves.
#
# A dead internal link is how the missing protocol pages were found: UXNib linked
# UXDesignable and the target did not exist, because docgen scanned `class` only
# and all ten protocols had no page. The Astro build does not fail on a dead
# internal link, so nothing caught it — and these pages cross-link heavily enough
# that it will happen again.
#
# Nine known-broken links are reported and not failed on: historical.md offers
# xtc 0.1/0.11/0.12 archives that are not in website/downloads/. See the note in
# check_links.py.
set -e
here=$(cd "$(dirname "$0")" && pwd)
site="$here/../../website/site"
[ -f "$site/check_links.py" ] || { echo "== doc-links: no checker =="; exit 1; }
python3 "$site/check_links.py"
echo "== doc-links: OK =="
