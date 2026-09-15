#!/bin/sh
# run_doc_coverage.sh — the `doc-coverage` report: which public methods have no
# reference section.
#
# run_doc_api.sh asks "is everything documented REAL?". This asks the other
# half — "is everything real DOCUMENTED?" — which is what the
# undocumented-methods task was actually about and which nothing had measured.
#
# REPORTS, it does not fail. Some methods genuinely are internal plumbing and
# the judgement of which is a person's, so a hard gate here would either be
# ignored or would force stub sections nobody wants. The judgements already
# made are recorded IN the checker with their reasons (protocol implementations
# are documented once on the protocol; UXFilePanel's surface is `run` and the
# page says so; the native* readback seam is driver-facing), so the number that
# remains is real rather than noise.
#
# Pass --strict to make it fail, if you want it as a gate in some other context.
set -e
here=$(cd "$(dirname "$0")" && pwd)
site="$here/../../website/site"
[ -f "$site/check_coverage.py" ] || { echo "== doc-coverage: no checker =="; exit 1; }
python3 "$site/check_coverage.py" "$@"
