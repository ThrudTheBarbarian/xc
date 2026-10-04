#!/bin/sh
# build_libuxgtk.sh — libUXGtk.so, UXKit's GTK 4 shim (libUXGtk.c) as a shared library, for an app
# linked in-house for Linux:
#
#     xcc -A x86_64 -dynamic app.xc -L <dir> -lUXGtk -lgtk-4 [-lGL]
#
# It is built with the machine's C compiler against its GTK 4, so it runs on a Linux machine with
# the GTK 4 development files: here, or on UX_LINUX_HOST (XTC_LINUX_HOST when that is empty) from
# a Mac.  The library lands in <out> (default ./linux-x86_64).  --with-link-inputs also copies the
# machine's libgtk-4.so and libGL.so there, which a Mac needs to link against.
#   sh build_libuxgtk.sh [out] [--with-link-inputs]
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
out=${1:-linux-x86_64}
case "$out" in --*) out=linux-x86_64 ;; esac
inputs=0
for a in "$@"; do [ "$a" = --with-link-inputs ] && inputs=1; done
mkdir -p "$out"
build='gcc -shared -fPIC -O2 libUXGtk.c $(pkg-config --cflags --libs gtk4) -o libUXGtk.so'
if [ "$(uname -s)" = Linux ]; then
  ( cd "$here" && sh -c "$build" && mv libUXGtk.so "$OLDPWD/$out/" )
  if [ $inputs = 1 ]; then
    cp "$(readlink -f "$(gcc -print-file-name=libgtk-4.so)")" "$out/libgtk-4.so"
    cp "$(readlink -f "$(gcc -print-file-name=libGL.so)")" "$out/libGL.so"
  fi
else
  host=${UX_LINUX_HOST:-${XTC_LINUX_HOST:-}}
  [ -n "$host" ] || { echo "build_libuxgtk: not Linux, and no UX_LINUX_HOST in build.env"; exit 1; }
  rdir=$(ssh -o BatchMode=yes "$host" 'mktemp -d')
  trap 'ssh -o BatchMode=yes "$host" "rm -rf $rdir" 2>/dev/null' EXIT
  scp -q "$here/libUXGtk.c" "$here/ux_posix_fs.h" "$host:$rdir/"
  ssh -o BatchMode=yes "$host" "cd $rdir && $build"
  scp -q "$host:$rdir/libUXGtk.so" "$out/"
  if [ $inputs = 1 ]; then
    ssh -o BatchMode=yes "$host" "cd $rdir && cp \$(readlink -f \$(gcc -print-file-name=libgtk-4.so)) libgtk-4.so && cp \$(readlink -f \$(gcc -print-file-name=libGL.so)) libGL.so"
    scp -q "$host:$rdir/libgtk-4.so" "$host:$rdir/libGL.so" "$out/"
  fi
fi
echo "build_libuxgtk: $out/libUXGtk.so"
