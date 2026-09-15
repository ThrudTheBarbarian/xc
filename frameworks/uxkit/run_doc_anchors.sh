#!/bin/sh
# run_doc_anchors.sh — the `doc-anchors` gate: every #fragment in the docs
# points at a heading that exists.
#
# run_doc_links.sh deliberately strips the fragment and checks only the page,
# so an anchor had never been verified by anything. These pages are dense with
# them — a Topics line is a dozen `[name](#name)` links — and a heading renamed
# once silently breaks every link to it. The Astro build does not care.
#
# The first run found 77 dead anchors across 24 pages, including three cases
# where the Topics line promised a reference section that was never written
# (UXStr.toInt, UXFont.italicized, UXGraphics.strokeNative). So it catches
# missing DOCUMENTATION, not just broken links.
#
# Not UXKit-specific: it walks the whole docs tree.
set -e
here=$(cd "$(dirname "$0")" && pwd)
site="$here/../../website/site"
[ -f "$site/check_anchors.py" ] || { echo "== doc-anchors: no checker =="; exit 1; }
python3 "$site/check_anchors.py" || { echo "== doc-anchors: FAILED =="; exit 1; }
echo "== doc-anchors: OK =="
