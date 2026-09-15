#!/bin/sh
# run_gtk_linux.sh — the GTK gate on REAL Linux (`gtk-mouse`): the same
# test_gtk_mouse.xc, cross-built for x86_64 and run on a Linux host under
# Xvfb.  Skips cleanly when the host is unreachable.
#
# The hybrid link (proven while filing bug 033): xcc emits gas-clean Intel
# .s; on the Linux host gcc assembles it, clang compiles the runtime's
# rt.c against glibc, rtgen-linux.s (addrsig stripped, symbols weakened)
# fills the xtc-specific holes while glibc keeps the common ones, and the
# GTK shim links it all into an ordinary dynamic PIE.  Needs the compiler
# fixed for 033 (x86_64 vtable calls dropped stack args) — before that fix
# the first draw dies in structAbsFrame, which is exactly what the gate
# proves fixed.
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
set -e
here=$(cd "$(dirname "$0")" && pwd)
xcc=${XCC:-xcc}
# The Linux machine is UX_LINUX_HOST, or XTC_LINUX_HOST when that is empty
# (both in build.env).
host=${UX_LINUX_HOST:-${XTC_LINUX_HOST:-}}
rtdir=$(dirname "$(command -v "$xcc")")/../lib/xc/x86_64/runtime
rtsrc=${XT_RT_SRC:-"$here/../../compiler"}
ssh -o ConnectTimeout=8 -o BatchMode=yes "$host" true 2>/dev/null || { echo "== gtk-mouse: skipped (no $host) =="; exit 0; }
ssh "$host" 'pkg-config --exists gtk4 && which xvfb-run' >/dev/null 2>&1 || { echo "== gtk-mouse: skipped (no gtk4/xvfb on $host) =="; exit 0; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== gtk-mouse: emitting x86_64 asm =="
"$xcc" -A x86_64 -I "$here" "$here/test_gtk_mouse.xc" -o "$work/test.s" -q 2>/dev/null

echo "== gtk-mouse: building the hybrid on $host =="
rdir=$(ssh "$host" 'mktemp -d')
ssh "$host" "mkdir -p $rdir/src/xtc/support-src $rdir/support/generic/runtime"
scp -q "$work/test.s" "$here/libUXGtk.c" "$rtdir/rtgen-linux.s" "$host:$rdir/"
scp -q "$rtsrc/src/xtc/support-src/rt.c" "$host:$rdir/src/xtc/support-src/"
scp -q "$rtsrc"/support/generic/runtime/*.c "$host:$rdir/support/generic/runtime/"
ssh "$host" "cd $rdir && \
    clang -c -O1 src/xtc/support-src/rt.c -o rt.o && objcopy --weaken-symbol=_putc rt.o && \
    sed '/\\.addrsig/d' rtgen-linux.s > rtgen2.s && gcc -c rtgen2.s -o rtgen.o && objcopy --weaken rtgen.o && \
    gcc -c test.s -o test.o && \
    cc -c libUXGtk.c \$(pkg-config --cflags gtk4) -o shim.o && \
    gcc test.o shim.o rt.o rtgen.o \$(pkg-config --libs gtk4) -lm -o gtk_mouse"

echo "== gtk-mouse: running under Xvfb =="
out=$(ssh "$host" "cd $rdir && timeout 60 xvfb-run -a ./gtk_mouse 2>&1 | grep -v Warning") || true
ssh "$host" "rm -rf $rdir"
echo "$out"
echo "$out" | grep -q "^PASS\|^SKIP" || { echo "== gtk-mouse: FAILED =="; exit 1; }
echo "== gtk-mouse: OK — presses reach views and drags track on REAL Linux =="
