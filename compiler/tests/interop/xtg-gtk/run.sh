#!/bin/sh
# Spike 1 (Linux/GTK) — the GTK counterpart of the Win32 driver (tests/interop/
# xtg-spike1). GTK is a plain C API, so it behaves like Win32, not the ObjC
# novelty of AppKit: xtc drives GTK4 directly and a GObject signal callback with
# a user_data context is the reverse map. See Rocks/doc/XTG-MULTIPLATFORM.md §10.
#
# Plumbing note: the x86_64 host (XTC_X86_HOST, or XTC_LINUX_HOST) has
# the GTK RUNTIME .so's but no -dev headers / pkg-config and no sudo. So the
# wrapper `.so` is built there against the versioned libgtk-4.so.1 by path with
# no headers (the C ABI is hand-declared), fetched back, linked into the xtc app
# on the Mac, and run under Xvfb (GTK needs a display).
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
xtc="$root/bin/osx/xcc"
exp="$(cat "$here/expected.out")"
HOST="${XTC_X86_HOST:-${XTC_LINUX_HOST:-}}"
L=/usr/lib/x86_64-linux-gnu

ssh -o ConnectTimeout=6 -o BatchMode=yes "$HOST" true 2>/dev/null || { echo "== skipped ($HOST unreachable) =="; exit 0; }
ssh -o BatchMode=yes "$HOST" "test -e $L/libgtk-4.so.1 && command -v xvfb-run cc >/dev/null" 2>/dev/null \
    || { echo "== skipped ($HOST lacks GTK4 runtime / Xvfb / cc) =="; exit 0; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
rd="/tmp/xtg-gtk-run.$$"
ssh -o BatchMode=yes "$HOST" "mkdir -p $rd"
trap 'rm -rf "$work"; ssh -o BatchMode=yes "$HOST" "rm -rf $rd" 2>/dev/null' EXIT

# 1. build the wrapper .so on the host (versioned GTK .so's by path, no headers)
scp -o BatchMode=yes -q "$here/gtkshim.c" "$HOST:$rd/"
ssh -o BatchMode=yes "$HOST" "cd $rd && cc -shared -fPIC -Wl,-soname,libgtkshim.so gtkshim.c \
    $L/libgtk-4.so.1 $L/libgobject-2.0.so.0 $L/libglib-2.0.so.0 -o libgtkshim.so"
scp -o BatchMode=yes -q "$HOST:$rd/libgtkshim.so" "$work/"

# 2. link the xtc app against it on the Mac
"$xtc" -H "$root" -A x86_64 -L "$work" -o "$work/app" "$here/gtk_driver.xc" -q 2>/dev/null

# 3. run under Xvfb on the host
scp -o BatchMode=yes -q "$work/libgtkshim.so" "$work/app" "$HOST:$rd/"
got=$(ssh -o BatchMode=yes "$HOST" "cd $rd && chmod +x app && \
    LD_LIBRARY_PATH=. GDK_BACKEND=x11 xvfb-run -a ./app 2>/dev/null")
if [ "$got" = "$exp" ]; then echo "== Linux/GTK4 (x86_64, Xvfb): PASS =="; exit 0
else echo "== Linux/GTK4: FAIL =="; printf 'want:\n%s\ngot:\n%s\n' "$exp" "$got"; exit 1; fi
