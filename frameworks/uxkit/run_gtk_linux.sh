#!/bin/sh
# run_gtk_linux.sh — the GTK gate on REAL Linux (`gtk-linux`): the same
# test_gtk_real.xc, cross-built for x86_64 and run on a Linux host under
# Xvfb.  Skips cleanly when the host is unreachable.
#
# xcc builds and links the test itself (glibc, dynamic) against libUXGtk.so and the
# host's GTK 4, as a user's program is built; the binary, libUXGtk.so and xcc's
# libRuntime.so (0.9.2 on) go to the host together.
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
test=${1:-test_gtk_real} # another GTK test to run on the Linux host, e.g. test_gtk_gl
# The Linux machine is UX_LINUX_HOST, or XTC_LINUX_HOST when that is empty
# (both in build.env).  UX_LINUX_XCFLAGS adds xcc options (a test's -D), UX_LINUX_LIBS adds libraries to the link (a test's -lGL, say), UX_LINUX_FILES
# files to copy beside the binary, and UX_LINUX_SETUP a command run in that directory before it.
host=${UX_LINUX_HOST:-${XTC_LINUX_HOST:-}}
ssh -o ConnectTimeout=8 -o BatchMode=yes "$host" true 2>/dev/null || { echo "== gtk-linux: skipped (no $host) =="; exit 0; }
ssh "$host" 'pkg-config --exists gtk4 && which xvfb-run' >/dev/null 2>&1 || { echo "== gtk-linux: skipped (no gtk4/xvfb on $host) =="; exit 0; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== gtk-linux: building $test for x86_64 (xcc links it, against the host's GTK 4) =="
sh "$here/tools/build_libuxgtk.sh" "$work/lib" --with-link-inputs >/dev/null
"$xcc" -A x86_64 -I "$here" ${UX_LINUX_XCFLAGS:-} "$here/$test.xc" -L "$work/lib" -lUXGtk -lgtk-4 ${UX_LINUX_LIBS:-} \
    -o "$work/gtk_real" -q 2>/dev/null
# From 0.9.2 a Linux program needs xcc's libRuntime.so beside it on a machine without xcc.
rt=$(dirname "$("$xcc" --print-3p-dir 2>/dev/null)")/lib/xc/runtime-lib/x86_64-linux/libRuntime.so
[ -f "$rt" ] || rt=
rdir=$(ssh "$host" 'mktemp -d')
scp -q "$work/gtk_real" "$work/lib/libUXGtk.so" $rt ${UX_LINUX_FILES:-} "$host:$rdir/"

echo "== gtk-linux: running under Xvfb =="
out=$(ssh "$host" "cd $rdir && ${UX_LINUX_SETUP:-true} && LD_LIBRARY_PATH=$rdir xvfb-run -a ./gtk_real 2>&1 | grep -v Warning") || true
ssh "$host" "rm -rf $rdir"
echo "$out"
echo "$out" | grep -q "^PASS\|^SKIP" || { echo "== gtk-linux: FAILED =="; exit 1; }
echo "== gtk-linux: OK — the neutral layer runs native on REAL Linux =="
