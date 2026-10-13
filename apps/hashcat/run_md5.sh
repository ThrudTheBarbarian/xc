#!/bin/sh
# Build md5.xc and run it on each device, printing the hashes per second.
# XCC names the compiler to use; it defaults to xcc on the PATH.
set -e
here=$(cd "$(dirname "$0")" && pwd)
XCC=${XCC:-xcc}
mkdir -p "$here/build"

"$XCC" -O3 -o "$here/build/md5" "$here/md5.xc"

echo "== self-test =="
"$here/build/md5" -t

echo "== serial =="
XC_PAR=cpu XC_PAR_THREADS=1 "$here/build/md5" >/dev/null

echo "== cpu =="
XC_PAR=cpu "$here/build/md5" >/dev/null

echo "== gpu =="
XC_PAR=gpu "$here/build/md5" >/dev/null

echo "== auto =="
"$here/build/md5" >/dev/null
