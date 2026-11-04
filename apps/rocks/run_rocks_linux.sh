#!/bin/sh
# run_rocks_linux.sh — the `rocks-linux` gate: Rocks cross-built for x86_64 and
# linked and run on a Linux machine, through the GTK driver, under Xvfb.
#
# The machine is UX_LINUX_HOST, or XTC_LINUX_HOST when that is empty (both in
# build.env). The gate prints which host it used, so a skipped Linux leg is
# never read as a pass.
#
# xcc builds and links Rocks itself (glibc, dynamic) against libUXGtk.so and the
# host's GTK 4, as a user's program is built; the program, libUXGtk.so and xcc's
# libRuntime.so (0.9.2 on) go to the host together.
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
set -e
here=$(cd "$(dirname "$0")" && pwd)
ux="$here/../../frameworks/uxkit"
xcc=${XCC:-xcc}
host=${UX_LINUX_HOST:-${XTC_LINUX_HOST:-}}

command -v "$xcc" >/dev/null 2>&1 || { echo "== rocks-linux: no compiler ('$xcc'); set XCC =="; exit 2; }
ssh -o ConnectTimeout=8 -o BatchMode=yes "$host" true 2>/dev/null \
    || { echo "== rocks-linux: skipped (no $host) =="; exit 0; }
ssh "$host" 'bash -lc "pkg-config --exists gtk4 && which xvfb-run >/dev/null"' 2>/dev/null \
    || { echo "== rocks-linux: skipped ($host has no gtk4/xvfb — apt install libgtk-4-dev xvfb) =="; exit 0; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "== rocks-linux: building for x86_64 (xcc links it, against the host's GTK 4) =="
sh "$ux/tools/build_libuxgtk.sh" "$work/lib" --with-link-inputs >/dev/null
"$xcc" -A x86_64 -I "$ux" -I "$here/xc" "$here/xc/rocks_main.xc" -L "$work/lib" -lUXGtk -lgtk-4 -lGL -o "$work/rocks" -q
# From 0.9.2 a Linux program needs xcc's libRuntime.so beside it on a machine without xcc.
rt=$(dirname "$("$xcc" --print-3p-dir 2>/dev/null)")/lib/xc/runtime-lib/x86_64-linux/libRuntime.so
[ -f "$rt" ] || rt=
R=$(ssh "$host" 'mktemp -d')
scp -q "$work/rocks" "$work/lib/libUXGtk.so" $rt "$host:$R/"

echo "== rocks-linux: running under Xvfb =="
# The GUI loop never returns, so the gate is the startup banner: the window was
# built and every wiring name resolved.  timeout is the exit, not a failure.
out=$(ssh "$host" "cd $R && bash -lc 'LD_LIBRARY_PATH=$R timeout 25 xvfb-run -a ./rocks 2>&1 | grep -v Warning | grep -v libEGL'") || true
ssh "$host" "rm -rf $R"
echo "$out" | tail -3
echo "$out" | grep -q "^PASS" || { echo "== rocks-linux: FAILED =="; exit 1; }
echo "== rocks-linux ($host): OK — Rocks builds, links and runs on real Linux =="
