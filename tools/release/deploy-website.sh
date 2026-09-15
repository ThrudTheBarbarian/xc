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

echo "== build =="
( cd "$SITE" && npm run build )

if [ -n "${FEEDBACK_RECIPIENT:-}" ]; then
  printf "<?php\nconst RECIPIENT = '%s';\n" "$FEEDBACK_RECIPIENT" > "$SITE/dist/feedback/config.php"
else
  echo "deploy: FEEDBACK_RECIPIENT is empty; the feedback form will refuse messages"
fi

echo "== publish site -> $HOST:$DOCROOT (archives preserved) =="
rsync -az --delete --exclude='/downloads/' "$SITE/dist/" "$HOST:$DOCROOT/"

if ls "$DL"/*.tar.bz2 "$DL"/*.zip >/dev/null 2>&1; then
  echo "== publish archives -> $HOST:$DOCROOT/downloads =="
  ssh "$HOST" "mkdir -p $DOCROOT/downloads"
  rsync -az "$DL"/*.tar.bz2 "$DL"/*.zip "$HOST:$DOCROOT/downloads/"
else
  echo "== no archives in $DL — skipping (site still references /downloads/*) =="
fi

echo "== done =="
