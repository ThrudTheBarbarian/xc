#!/bin/sh
# run_appkit_liveresize.sh -- AppKit live resize (demo_appkit_liveresize): the toolkit hears the resize
# during the drag, the window follows it, and the app's turn keeps firing in the tracking run-loop mode.
# Run twice: plainly, and under guard malloc, since this path once corrupted the heap.  Guard malloc's
# teardown after the app stops varies from seconds to about a minute, hence its long limit.
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
case "$(uname)" in Darwin) ;; *) echo "== appkit-liveresize: skipped (not macOS) =="; exit 0 ;; esac

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== appkit-liveresize: building the ObjC shim + the demo for arm64 =="
cc -fobjc-arc -fno-objc-msgsend-selector-stubs -dynamiclib -install_name "$work/libUXAppKit.dylib" "$here/libUXAppKit.m" -framework Cocoa -framework OpenGL -o "$work/libUXAppKit.dylib" 2>/dev/null
"$xcc" -A arm64 -I "$here" "$here/demo_appkit_liveresize.xc" \
    -Xlinker "$work/libUXAppKit.dylib" -framework Cocoa -framework OpenGL -o "$work/demo_appkit_liveresize" -q 2>/dev/null

rc=0
for mode in plain guard-malloc; do
  echo "== appkit-liveresize: $mode =="
  if [ "$mode" = plain ]; then
    out=$(timeout 30 "$work/demo_appkit_liveresize" 2>&1) || true
  else
    out=$(MallocScribble=1 DYLD_INSERT_LIBRARIES=/usr/lib/libgmalloc.dylib timeout 240 "$work/demo_appkit_liveresize" 2>&1) || true
  fi
  printf '%s\n' "$out" | grep -v 'GuardMalloc'
  printf '%s\n' "$out" | grep -q '^PASS' || rc=1
done
[ $rc = 0 ] && echo "== appkit-liveresize: OK ==" || echo "== appkit-liveresize: FAILED =="
exit $rc
