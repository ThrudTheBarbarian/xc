#!/bin/bash
# c-runtime-support.sh — a C program whose loop is lifted links the target's
# libRuntimeSupport (#278): the par runtime and the standard library it uses,
# prebuilt, so the program defines none of the Foundation classes (no String$,
# Array$, Number$ code of its own), loads that one runtime library and not
# libRuntime as well, and gives clang's answer. Skipped where there is no
# clang or the host target has no libRuntimeSupport built.
#
#   bash tests/driver/c-runtime-support.sh
set -u
export XC_PAR_REMOTE=none
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
clang --version > /dev/null 2>&1 || { echo "--- c-runtime-support: skipped (no clang) ---"; exit 0; }
case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) ROW=arm64-macos; EXT=dylib ;;
    Linux-x86_64) ROW=x86_64-linux; EXT=so ;;
    Linux-aarch64) ROW=arm64-linux; EXT=so ;;
    *) echo "--- c-runtime-support: skipped (host) ---"; exit 0 ;;
esac
[ -f "support/runtime-lib/$ROW/libRuntimeSupport.$EXT" ] || { echo "--- c-runtime-support: skipped (no libRuntimeSupport for $ROW) ---"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
fail=0
cat > "$W/lift.c" <<'C'
#include <stdio.h>
#define N 1000000
double a[N], b[N];
int main(void)
{
    for (int i = 0; i < N; i++)
        b[i] = i * 0.5;
    for (int i = 0; i < N; i++)
        a[i] = 3.0 * b[i] + 1.0;
    double t = 0;
    for (int i = 0; i < N; i++)
        t += a[i];
    printf("%.1f\n", t);
    return 0;
}
C
clang -O2 -w -o "$W/ref" "$W/lift.c" || { echo "FAIL c-runtime-support: clang does not build lift.c"; exit 1; }
want=$("$W/ref")
"$XC" -q -O2 -H . -o "$W/lift" "$W/lift.c" > "$W/b" 2>&1 || { echo "FAIL c-runtime-support: lift.c does not build"; head -5 "$W/b"; exit 1; }
got=$(XC_PAR=cpu "$W/lift" 2>&1)
[ "$got" = "$want" ] && echo "  ok: lift gives clang's answer ($got)" || { echo "  FAIL: lift gives '$got', clang's '$want'"; fail=1; }
# Foundation code the program defines itself (T/t: text): none.
own=$(nm "$W/lift" 2>/dev/null | grep -E ' [Tt] ' | grep -cE ' _?(String|Array|Number|Map)\$')
[ "$own" = 0 ] && echo "  ok: lift defines no Foundation code" || { echo "  FAIL: lift defines $own Foundation function(s)"; nm "$W/lift" | grep -E ' [Tt] ' | grep -E ' _?(String|Array|Number|Map)\$' | head -3; fail=1; }
if [ "$PLAT" = osx ]; then libs=$(otool -L "$W/lift" | tail -n +2); else libs=$(readelf -d "$W/lift" | grep NEEDED); fi
echo "$libs" | grep -q "libRuntimeSupport\.$EXT" && echo "  ok: lift loads libRuntimeSupport" || { echo "  FAIL: lift does not load libRuntimeSupport"; fail=1; }
echo "$libs" | grep -q "libRuntime\.$EXT" && { echo "  FAIL: lift loads libRuntime as well"; fail=1; } || echo "  ok: lift loads no libRuntime beside it"
n=$(echo "$libs" | grep -c "libRuntimeSupport\.$EXT")
[ "$n" = 1 ] || { echo "  FAIL: lift loads libRuntimeSupport $n times"; fail=1; }
# Its loops still run as blocks.
"$XC" -q -O2 -H . -Wpar-auto -o "$W/lift2" "$W/lift.c" > "$W/w" 2>&1
grep -q "became a 'par' block" "$W/w" && echo "  ok: lift's loops are lifted" || { echo "  FAIL: lift's loops were not lifted"; head -3 "$W/w"; fail=1; }
echo "--- c-runtime-support: $([ $fail = 0 ] && echo pass || echo FAIL) ---"
exit $fail
