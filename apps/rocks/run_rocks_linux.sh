#!/bin/sh
# run_rocks_linux.sh — the `rocks-linux` gate: Rocks cross-built for x86_64 and
# linked and run on a Linux machine, through the GTK driver, under Xvfb.
#
# The machine is UX_LINUX_HOST, or XTC_LINUX_HOST when that is empty (both in
# build.env). The gate prints which host it used, so a skipped Linux leg is
# never read as a pass.
#
# The hybrid link (shared with run_gtk_linux.sh): xcc
# emits gas-clean Intel .s; gcc assembles it, clang builds the runtime's rt.c
# against glibc, rtgen-linux.s fills the xtc-specific holes with its symbols
# weakened so glibc keeps the common ones, and the GTK shim links it all into an
# ordinary dynamic PIE.
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
set -e
here=$(cd "$(dirname "$0")" && pwd)
ux="$here/../../frameworks/uxkit"
xcc=${XCC:-xcc}
host=${UX_LINUX_HOST:-${XTC_LINUX_HOST:-}}
rtdir=$(dirname "$(command -v "$xcc")")/../lib/xc/x86_64/runtime
rtsrc=${XT_RT_SRC:-"$here/../../compiler"}

command -v "$xcc" >/dev/null 2>&1 || { echo "== rocks-linux: no compiler ('$xcc'); set XCC =="; exit 2; }
ssh -o ConnectTimeout=8 -o BatchMode=yes "$host" true 2>/dev/null \
    || { echo "== rocks-linux: skipped (no $host) =="; exit 0; }
ssh "$host" 'bash -lc "pkg-config --exists gtk4 && which xvfb-run >/dev/null"' 2>/dev/null \
    || { echo "== rocks-linux: skipped ($host has no gtk4/xvfb — apt install libgtk-4-dev xvfb) =="; exit 0; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== rocks-linux: emitting x86_64 asm =="
"$xcc" -A x86_64 -I "$ux" -I "$here/xc" "$here/xc/rocks_main.xc" -o "$work/rocks.s" -q

echo "== rocks-linux: hybrid link on $host =="
R=$(ssh "$host" 'mktemp -d')
ssh "$host" "mkdir -p $R/src/xtc/support-src $R/support/generic/runtime"
scp -q "$work/rocks.s" "$rtdir/rtgen-linux.s" "$ux/libUXGtk.c" "$host:$R/"
scp -q "$rtsrc/src/xtc/support-src/rt.c" "$host:$R/src/xtc/support-src/"
scp -q "$rtsrc"/support/generic/runtime/*.c "$host:$R/support/generic/runtime/"
ssh "$host" "cd $R && bash -lc '
  clang -c -O1 src/xtc/support-src/rt.c -o rt.o && objcopy --weaken-symbol=_putc rt.o &&
  sed \"/\.addrsig/d\" rtgen-linux.s > rtgen2.s && gcc -c rtgen2.s -o rtgen.o && objcopy --weaken rtgen.o &&
  gcc -c rocks.s -o rocks.o &&
  cc -c libUXGtk.c \$(pkg-config --cflags gtk4) -o shim.o &&
  gcc rocks.o shim.o rt.o rtgen.o \$(pkg-config --libs gtk4) -lm -o rocks'"

echo "== rocks-linux: running under Xvfb =="
# The GUI loop never returns, so the gate is the startup banner: the window was
# built and every wiring name resolved.  timeout is the exit, not a failure.
out=$(ssh "$host" "cd $R && bash -lc 'timeout 25 xvfb-run -a ./rocks 2>&1 | grep -v Warning | grep -v libEGL'") || true
ssh "$host" "rm -rf $R"
echo "$out" | tail -3
echo "$out" | grep -q "^PASS" || { echo "== rocks-linux: FAILED =="; exit 1; }
echo "== rocks-linux ($host): OK — Rocks builds, links and runs on real Linux =="
