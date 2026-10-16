#!/bin/sh
# Build website/site and publish it with rsync over ssh.
#
#   website/site/       the Starlight/astro source        -> built to dist/
#   website/downloads/  the release archives the site links (gitignored, large)
#
# The target is DEPLOY_HOST:DEPLOY_DOCROOT, both set in build.env. The archive
# area <docroot>/downloads is served statically and is not part of the astro
# build: it is deployed separately and kept across site deploys. The anchored
# --exclude=/downloads/ below matters, because an unanchored 'downloads/' would
# also drop the astro /compiler/downloads/ docs.
#
# The feedback form's recipient is FEEDBACK_RECIPIENT in build.env. It is
# written into the published site as feedback/config.php.
#
# Node note: astro 6 needs node >= 22.12, but sharp 0.34's prebuilt @img
# binaries did not install under the very newest node here, so it tried (and
# failed) to build sharp from source. The working recipe is: populate
# node_modules once with a node that has the sharp prebuilt (a matching sibling
# tree's node_modules works — same sharp version), then `npm run build` under
# whatever node >= 22.12 is default. This script only BUILDS + PUBLISHES; it
# assumes node_modules is present.
set -e
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
SITE="$ROOT/website/site"
DL="$ROOT/website/downloads"
. "$ROOT/tools/build-env.sh"
HOST=${DEPLOY_HOST:-}
DOCROOT=${DEPLOY_DOCROOT:-}
[ -n "$HOST" ] && [ -n "$DOCROOT" ] || {
  echo "deploy: set DEPLOY_HOST and DEPLOY_DOCROOT in build.env (see build.env.template)"
  exit 1
}

[ -d "$SITE/node_modules/@img" ] || {
  echo "deploy: $SITE/node_modules is missing sharp's @img prebuilt."
  echo "  Install deps first with a node that ships the sharp prebuilt, e.g.:"
  echo "    (cd website/site && npm install)      # or copy a working node_modules in"
  exit 1
}

# The documentation is versioned (website/site/tools/docversions.py): the
# default tree describes one version with no "from 0.72" marks, and each
# release keeps its own tree under versions/<ver>/. So a deploy publishes the
# docs of the commit it is built from as if they were released: from a release
# tag only, unless DEPLOY_UNRELEASED=1 says to publish unreleased docs anyway.
TAG=$(git describe --exact-match --tags --match 'v*' HEAD 2>/dev/null || true)
if [ -z "$TAG" ] && [ "${DEPLOY_UNRELEASED:-0}" != 1 ]; then
  echo "deploy: HEAD is not a release tag, so its docs would go live as released."
  echo "  Deploy from the release's tag (a clean worktree), or set DEPLOY_UNRELEASED=1."
  exit 1
fi
python3 "$SITE/tools/docversions.py" strip --check >/dev/null || {
  echo "deploy: the current docs mention versions; run:"
  echo "    python3 website/site/tools/docversions.py strip --check"
  exit 1
}
LATEST=$(git tag --list 'v*' | sed 's/^v//' | python3 -c "import sys
def k(s):
    p=s.split('.'); m=p[1]; return (int(p[0]), int(m)*(10 if len(m)==1 else 1), int(p[2]) if len(p)>2 else 0)
print(max(sys.stdin.read().split(), key=k))")
[ -d "$SITE/src/content/docs/versions/$LATEST" ] || {
  echo "deploy: release $LATEST has no documentation tree of its own; run:"
  echo "    python3 website/site/tools/docversions.py snapshot v$LATEST"
  exit 1
}

echo "== build =="
( cd "$SITE" && npm run build )

# The live demos: a tutorial's program built for the web, beside its page in
# public/demo/<name>/ (which holds only the page). UXKit is compiled in from
# the repository, so the demo is the published source, built by the xcc on
# PATH (or XCC in build.env).
XCC=${XCC:-xcc}
command -v "$XCC" >/dev/null 2>&1 || {
  echo "deploy: no xcc on PATH; set XCC in build.env (see build.env.template)"
  exit 1
}
echo "== build the live demos with $("$XCC" --version | head -1) =="
D="$SITE/dist/demo/mandelbrot"
"$XCC" -A wasm32 -O3 -q -I "$ROOT/frameworks/uxkit" -o "$D/mandelbrot.wasm" \
  "$SITE/examples/uxkit/mandelbrot.xc"
rm -f "$D/mandelbrot.html"    # xcc's console page; index.html is the demo's
cp "$ROOT/frameworks/uxkit/ux_web_page.js" "$ROOT/frameworks/uxkit/ux_web_browser.js" "$D/"

if [ -n "${FEEDBACK_RECIPIENT:-}" ]; then
  printf "<?php\nconst RECIPIENT = '%s';\n" "$FEEDBACK_RECIPIENT" > "$SITE/dist/feedback/config.php"
else
  echo "deploy: FEEDBACK_RECIPIENT is empty; the feedback form will refuse messages"
fi

echo "== publish site -> $HOST:$DOCROOT (archives and the benchmark corpus preserved) =="
# The corpus is what people have submitted through benchmarks/submit.php: it
# exists only on the server, so --delete must never reach it.
rsync -az --delete --exclude='/downloads/' --exclude='/benchmarks/corpus/' "$SITE/dist/" "$HOST:$DOCROOT/"

if ls "$DL"/*.tar.bz2 "$DL"/*.zip >/dev/null 2>&1; then
  echo "== publish archives -> $HOST:$DOCROOT/downloads =="
  ssh "$HOST" "mkdir -p $DOCROOT/downloads"
  rsync -az "$DL"/*.tar.bz2 "$DL"/*.zip "$HOST:$DOCROOT/downloads/"
else
  echo "== no archives in $DL — skipping (site still references /downloads/*) =="
fi

echo "== done =="
