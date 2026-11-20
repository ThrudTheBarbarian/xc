#!/bin/bash
# files-readtext-dir.sh — Files.readText and readData on a directory are null,
# as on Linux (#476). On macOS fopen opens a directory and fread reads nothing
# with the error set, which the runtime took for an empty file: "" not null.
#
#   bash tests/driver/files-readtext-dir.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}; case $XC in /*) ;; *) XC="$ROOT/$XC";; esac
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
mkdir -p "$W/adir"; printf 'hi\n' > "$W/afile"
cat > "$W/t.xc" <<'XC'
#import "Stdio.xc"
#import "Files.xc"
i32 main(void)
    {
    Stdio.printf("dir text %s\n", Files.readText(String.withCString("adir")) == (String*)0 ? "null" : "not null");
    Stdio.printf("dir data %s\n", Files.readData(String.withCString("adir")) == (Data*)0 ? "null" : "not null");
    String* t = Files.readText(String.withCString("afile"));
    Stdio.printf("file text %s\n", t == (String*)0 ? "null" : t.cString());
    return 0;
    }
XC
"$XC" -q -O2 -H "$ROOT" -o "$W/t" "$W/t.xc" > "$W/e" 2>&1 || { echo "FAIL files-readtext-dir: does not build: $(head -c 200 "$W/e")"; exit 1; }
got=$(cd "$W" && ./t)
want=$(printf 'dir text null\ndir data null\nfile text hi\n')
[ "$got" = "$want" ] && { echo "files-readtext-dir: ok"; exit 0; }
echo "FAIL files-readtext-dir: printed:"; echo "$got"; exit 1
