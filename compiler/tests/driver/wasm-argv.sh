#!/bin/bash
# wasm-argv.sh — a wasm32 program's main gets argc and argv under node (#457):
# argv[0] is the script, then the arguments after it. The loader called the
# exported main with nothing and the wrapper passed main zeros, so argc was
# always 0.
#
#   bash tests/driver/wasm-argv.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}; case $XC in /*) ;; *) XC="$ROOT/$XC";; esac
# node from PATH, or Homebrew's (a gate host's non-interactive PATH lacks it).
NODE=$(command -v node || ls /opt/homebrew/bin/node 2>/dev/null)
[ -n "$NODE" ] || { echo "wasm-argv: skipped (no node)"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
cat > "$W/a.xc" <<'XC'
#import "Stdio.xc"
i32 main(i32 argc, u8** argv)
    {
    Stdio.printf("argc %d\n", argc);
    for (i32 i = 1; i < argc; i++)
        Stdio.printf("arg %d [%s]\n", i, argv[i]);
    Stdio.printf("argv0 %d\n", (i32)(argc > 0 && argv[0] != (u8*)0 && argv[0][0] != (u8)0 ? 1 : 0));
    return 0;
    }
XC
fail=0
"$XC" -q -O2 -A wasm32 -H "$ROOT" -o "$W/a" "$W/a.xc" > "$W/e" 2>&1 || { echo "FAIL wasm-argv: does not build: $(head -c 200 "$W/e")"; exit 1; }
got=$(cd "$W" && "$NODE" a.js one "two words" 2>&1)
want=$(printf 'argc 3\narg 1 [one]\narg 2 [two words]\nargv0 1')
[ "$got" = "$want" ] || { echo "FAIL wasm-argv: with two arguments printed:"; echo "$got"; fail=1; }
got=$(cd "$W" && "$NODE" a.js 2>&1)
[ "$got" = "$(printf 'argc 1\nargv0 1')" ] || { echo "FAIL wasm-argv: with none printed:"; echo "$got"; fail=1; }
[ $fail = 0 ] && echo "wasm-argv: ok"
exit $fail
