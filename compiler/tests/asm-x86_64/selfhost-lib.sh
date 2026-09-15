#!/bin/sh
# selfhost-lib.sh — the cross-module story on the self-hosted Linux path: build a
# shared library and an app that `#import <Lib>`s it, with no Linux toolchain
# anywhere, and check the pair runs on Linux.
#
# This exercises the parts a static executable never touches: the `.xtc.iface`
# section the importer reads, DT_NEEDED, the GOT thunks, DT_RUNPATH $ORIGIN, and
# PT_PHDR/PT_INTERP (without which ld.so dies before it can even report why).
#
# The Linux host is XTC_LINUX_HOST (set in build.env).
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
[ -f "$_root/tools/build-env.sh" ] && . "$_root/tools/build-env.sh"
set -e
cd "$(dirname "$0")/../.."
ROOT=$(pwd)

HOST="${XTC_LINUX_HOST:-}"
[ -x bin/osx/xcc ] || { echo "build first: make"; exit 1; }
if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$HOST" true 2>/dev/null; then
    echo "selfhost-lib: SKIP (no Linux host '$HOST')"; exit 0
fi

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
cat > "$W/Greeter.xc" <<'EOF'
class Greeter
{
    static i32 triple(i32 n) { return n * 3; }
}
EOF
cat > "$W/app.xc" <<'EOF'
#import <Greeter>
#import "Stdio.xc"
void main(void)
{
    Stdio.printf("triple(14)=%d\n", Greeter.triple(14));
}
EOF
# A second library exercising what a static method does not: a heap-allocated
# instance, instance methods through the vtable, and ARC across the boundary.
cat > "$W/Counter.xc" <<'EOF'
class Counter
{
    i32 n;
    void bump(i32 by)   { n = n + by; }
    i32  value(void)    { return n; }
    static Counter@ make(void) { return new Counter(); }
}
EOF
cat > "$W/app2.xc" <<'EOF'
#import <Counter>
#import "Stdio.xc"
void main(void)
{
    Counter@ c = Counter.make();
    c.bump(20);
    c.bump(22);
    Stdio.printf("count=%d\n", c.value());
}
EOF

fail=0
check() {   # check <name> <expected> <got>
    printf '  %-46s' "$1"
    if [ "$2" = "$3" ]; then echo "ok"; else echo "FAIL (got '$3', want '$2')"; fail=1; fi
}

cd "$W"
libout=$("$ROOT"/bin/osx/xcc -A x86_64 --self-host --emit-lib Greeter.xc -o libGreeter.so 2>&1)
appout=$("$ROOT"/bin/osx/xcc -A x86_64 --self-host -L. app.xc -o app 2>&1)

# The driver falls back to clang if the in-house link fails, so "it ran" is not
# enough — confirm the self-hosted path is what produced each file.
case "$libout" in *"self-hosted, no clang"*) lib_sh=yes;; *) lib_sh=no;; esac
case "$appout" in *"self-hosted, no clang"*) app_sh=yes;; *) app_sh=no;; esac
check "library built without clang"  yes "$lib_sh"
check "app built without clang"      yes "$app_sh"

libout2=$("$ROOT"/bin/osx/xcc -A x86_64 --self-host --emit-lib Counter.xc -o libCounter.so 2>&1)
appout2=$("$ROOT"/bin/osx/xcc -A x86_64 --self-host -L. app2.xc -o app2 2>&1)
case "$libout2" in *"self-hosted, no clang"*) lib2_sh=yes;; *) lib2_sh=no;; esac
case "$appout2" in *"self-hosted, no clang"*) app2_sh=yes;; *) app2_sh=no;; esac
check "class library built without clang" yes "$lib2_sh"
check "class app built without clang"     yes "$app2_sh"

scp -q libGreeter.so app libCounter.so app2 "$HOST:/tmp/" || { echo "selfhost-lib: scp failed"; exit 1; }
# No LD_LIBRARY_PATH: DT_RUNPATH $ORIGIN has to do the work.
got=$(ssh "$HOST" 'cd /tmp && chmod +x app && ./app' 2>/dev/null) || true
check "app resolves the library and runs" "triple(14)=42" "$got"
got=$(ssh "$HOST" 'cd /tmp && chmod +x app2 && ./app2' 2>/dev/null) || true
check "heap + vtable + ARC across the .so" "count=42" "$got"

ssh "$HOST" 'rm -f /tmp/app /tmp/libGreeter.so /tmp/app2 /tmp/libCounter.so' 2>/dev/null || true
[ $fail = 0 ] && echo "selfhost-lib: all ok" || echo "selfhost-lib: FAILURES"
exit $fail
