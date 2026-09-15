#!/bin/sh
# run_doc_api.sh — the `doc-api` gate: every method signature the UXKit docs
# show is one the source actually declares.
#
# This exists because the docs are written by READING source, and reading is
# where invented API comes from. The doc pass has already shipped
# `slider.value()` and `selectItemWithTag` — neither existed. Both were caught
# only because they happened to sit in a compiled example; a signature quoted
# in prose had nothing checking it at all.
#
# Name-only, deliberately. Matching parameter lists would need a parser and
# would trip over the docs' own reformatting; the NAME is what a reader types,
# and a name that does not exist is the error worth catching.
#
# It checks a name only where the page CLAIMS it as API — a `###` reference
# heading. A snippet showing the reader's own handler is a signature they
# write, not one the framework declares.
set -e
here=$(cd "$(dirname "$0")" && pwd)
site="$here/../../website/site"
[ -f "$site/check_api.py" ] || { echo "== doc-api: no checker =="; exit 1; }
python3 "$site/check_api.py" || { echo "== doc-api: FAILED =="; exit 1; }
echo "== doc-api: OK =="
