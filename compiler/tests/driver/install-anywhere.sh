#!/bin/bash
# install-anywhere.sh — an install unpacked anywhere finds its own library
# when it is run from PATH (#61).
#
# The driver took its location from argv[0], which is plain `xcc` from PATH,
# so the library search fell through to /opt/xcc. A machine with an install
# there hid the bug; an archive unpacked anywhere else (a Raspberry Pi, as
# the downloads page says to) failed hello.xc with an empty search list.
#
# Checked: a copy of the compiler in a fresh <dir>/bin, with <dir>/lib/xc the
# support tree, run as `xcc` from PATH in an unrelated directory, searches
# <dir>/lib/xc and builds hello.xc, and the program runs where the target is
# the host's.
#
#   bash tests/driver/install-anywhere.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$PWD
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
case "$XC" in /*) ;; *) XC=$ROOT/$XC ;; esac
W=$(mktemp -d /tmp/install-anywhere.XXXX); trap 'rm -rf "${W:?}"' EXIT
mkdir -p "$W/inst/bin" "$W/inst/lib" "$W/elsewhere"
cp "$XC" "$W/inst/bin/xcc"
ln -s "$ROOT/support" "$W/inst/lib/xc"
printf '#import "Stdio.xc"\ni32 main(void) { Stdio.printf("found\\n"); return 0; }\n' > "$W/elsewhere/h.xc"
fail=0
out=$(cd "$W/elsewhere" && PATH="$W/inst/bin:$PATH" XCC_HOME= XTC_HOME= xcc -V -o h h.xc 2>&1)
echo "$out" | grep -q "$W/inst/lib/xc" || { echo "FAIL install-anywhere: the search did not use $W/inst/lib/xc:"; echo "$out" | head -5; fail=1; }
[ -x "$W/elsewhere/h" ] || { echo "FAIL install-anywhere: hello.xc did not build"; fail=1; }
[ $fail = 0 ] && [ "$("$W/elsewhere/h")" = found ] || { [ $fail = 1 ] || { echo "FAIL install-anywhere: the program did not print 'found'"; fail=1; }; }
[ $fail = 0 ] && echo "install-anywhere: ok"
exit $fail
