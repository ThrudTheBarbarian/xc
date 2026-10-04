#!/bin/sh
# run_gtk_dynamic.sh — the gtk-dynamic gate: UXKit apps for Linux linked in-house (xcc -A x86_64
# -dynamic, no C compiler for the app), against libUXGtk.so (tools/build_libuxgtk.sh), GTK 4 and
# libGL, and run on the Linux host under Xvfb: test_gtk_real, test_gl_renderer, test_gl_setup,
# test_lifecycle and test_socket.  Needs a compiler with -dynamic (XCC_WORKER, default the in-tree xcc-xc) and
# UX_LINUX_HOST; skips cleanly without either.
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
set -u
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC_WORKER:-"$here/../../compiler/bin/osx/xcc-xc"}
case "$xcc" in "$here/../../compiler/"*) export XCC_HOME=${XCC_HOME:-"$(cd "$here/../../compiler" && pwd)"} ;; esac
host=${UX_LINUX_HOST:-${XTC_LINUX_HOST:-}}
[ -x "$xcc" ] && "$xcc" --help 2>&1 | grep -q -- '-dynamic' || { echo "== gtk-dynamic: skipped (no compiler with -dynamic) =="; exit 0; }
[ -n "$host" ] && ssh -o ConnectTimeout=8 -o BatchMode=yes "$host" true 2>/dev/null || { echo "== gtk-dynamic: skipped (no Linux host) =="; exit 0; }
work=$(mktemp -d)
rdir=$(ssh -o BatchMode=yes "$host" 'mktemp -d')
trap 'ssh -o BatchMode=yes "$host" "rm -rf $rdir" 2>/dev/null; rm -rf "$work"' EXIT
echo "== gtk-dynamic: libUXGtk.so on the Linux host =="
sh "$here/tools/build_libuxgtk.sh" "$work/lib" --with-link-inputs >/dev/null || { echo "== gtk-dynamic: FAILED (libUXGtk.so) =="; exit 1; }
echo "== gtk-dynamic: linking in-house (xcc -dynamic) =="
tests="test_gtk_real test_gl_renderer test_gl_setup test_lifecycle test_socket"
for t in $tests; do
  "$xcc" -A x86_64 -dynamic -I "$here" "$here/$t.xc" -L "$work/lib" -lUXGtk -lgtk-4 -lGL -o "$work/$t" -q || { echo "== gtk-dynamic: FAILED (linking $t) =="; exit 1; }
done
scp -q "$work/lib/libUXGtk.so" "$here/tools/echo_server.py" $(for t in $tests; do printf '%s ' "$work/$t"; done) "$host:$rdir/"
echo "== gtk-dynamic: running under Xvfb =="
out=$(ssh -o BatchMode=yes "$host" "cd $rdir && export LD_LIBRARY_PATH=$rdir && \
  for t in test_gtk_real test_gl_renderer test_gl_setup test_lifecycle; do xvfb-run -a ./\$t 2>&1 | grep -a '^PASS\|^FAIL'; done; \
  (nohup python3 echo_server.py > port.txt 2>/dev/null < /dev/null &); sleep 1; \
  UX_SOCKET_PORT=\$(cat port.txt) ./test_socket 2>&1 | grep -a '^PASS\|^FAIL'")
echo "$out"
[ "$(echo "$out" | grep -c '^PASS')" = 5 ] || { echo "== gtk-dynamic: FAILED =="; exit 1; }
echo "== gtk-dynamic: OK =="
