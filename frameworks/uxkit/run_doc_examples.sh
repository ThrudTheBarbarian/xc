#!/bin/sh
# run_doc_examples.sh — the `doc-examples` gate: every complete example in the
# UXKit guides compiles.
#
# A documented example is a promise: someone will paste it and expect it to
# build. These docs have already shipped a `^` sigil that no longer exists and a
# `weak:` qualifier that became a hard compile error — a build would have caught
# both the day they broke, and nothing was building them.
#
# Examples live in website/site/examples/uxkit/ and are the SAME text the guides
# show. Compile-only: these open windows, and a gate should not need a display.
set -e
here=$(cd "$(dirname "$0")" && pwd)
ex="$here/../../website/site/examples/uxkit"
xcc=${XCC:-xcc}
command -v "$xcc" >/dev/null 2>&1 || { echo "== doc-examples: no compiler ('$xcc'); set XCC =="; exit 2; }
case "$(uname)" in Darwin) ;; *) echo "== doc-examples: skipped (AppKit examples are macOS-only) =="; exit 0 ;; esac
[ -d "$ex" ] || { echo "== doc-examples: no examples directory =="; exit 1; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib \
   -install_name "$work/libUXAppKit.dylib" "$here/libUXAppKit.m" \
   -framework Cocoa -o "$work/libUXAppKit.dylib" 2>/dev/null

n=0; fail=""
for f in "$ex"/*.xc; do
  [ -e "$f" ] || continue
  b=$(basename "$f" .xc); n=$((n+1))
  if "$xcc" -A arm64 -I "$here" "$f" -Xlinker "$work/libUXAppKit.dylib" \
       -framework Cocoa -o "$work/$b" -q >"$work/$b.err" 2>&1
  then printf "  %-22s compiles\n" "$b"
  else printf "  %-22s FAILED\n" "$b"; sed 's/^/      /' "$work/$b.err" | head -4; fail="$fail $b"; fi
done

echo "== doc-examples: $((n - $(echo $fail | wc -w | tr -d ' ')))/$n compile =="
[ -z "$fail" ] || { echo "== doc-examples: FAILED —$fail =="; exit 1; }
echo "== doc-examples: OK =="
