#!/bin/bash
# bounds-hoist.sh — a heap check in a loop that cannot change the array's
# header compares against a bound computed before the loop, and calls the
# check only past it (issue #28). The check must still fail where it did: on
# the first index out of range, after the iterations before it have run, with
# the same report.
#
#   bash tests/driver/bounds-hoist.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
# fill(a, n) writes a[0..n): with n one past the end it must stop at index 10,
# on the iteration that reaches it. The case comes from argv, so nothing is constant.
cat > "$W/t.xc" <<'XC'
#import "Foundation.xc"

void fill(u32* a, u32 n)
{
    for (u32 i = (u32)0; i < n; i = i + (u32)1)
        a[i] = i + (u32)1;
}

u32 sumFrom(u32* a, u32 k, u32 n)
{
    u32* q = a + k;
    u32 s = (u32)0;
    for (u32 i = (u32)0; i < n; i = i + (u32)1)
        s = s + q[i];
    return s;
}

u32 grid(u32* a, u32 rows, u32 cols)
{
    u32 s = (u32)0;
    for (u32 r = (u32)0; r < rows; r = r + (u32)1)
        for (u32 c = (u32)0; c < cols; c = c + (u32)1)
            s = s + a[r * cols + c];
    return s;
}

void copyBytes(u8* d, u8* s, u32 n)
{
    for (u32 i = (u32)0; i < n; i = i + (u32)1)
        d[i] = s[i];
}

u32 find(Array* arr, Object* v)
{
    for (u32 i = (u32)0; i < arr.count(); i = i + (u32)1)
        if (arr.get(i) == v)
            return i;
    return arr.count();
}

i32 main(i32 argc, u8** argv)
{
    u32* a = new u32[10];
    u32 mode = (u32)argc;
    if (mode == (u32)1)
        {
        fill(a, (u32)10);
        Stdio.printf("ok %u %u %u\n", sumFrom(a, (u32)4, (u32)6), grid(a, (u32)2, (u32)5), a[9]);
        Array* arr = new Array();
        Object* v = (Object*)Number.with((u32)2);
        arr.add((Object*)Number.with((u32)1));
        arr.add(v);
        Stdio.printf("find %u\n", find(arr, v));
        u8* b = new u8[40];
        u8* c = new u8[40];
        for (u32 i = (u32)0; i < (u32)40; i = i + (u32)1)
            c[i] = (u8)i;
        copyBytes(b, c, (u32)40);
        Stdio.printf("copy %u %u\n", (u32)b[0], (u32)b[39]);
        return 0;
        }
    if (mode == (u32)6)
        {
        u8* b = new u8[10];
        u8* c = new u8[20];
        copyBytes(b, c, (u32)11);
        return 0;
        }
    if (mode == (u32)2)
        {
        Stdio.printf("before\n");
        fill(a, (u32)11);
        Stdio.printf("after\n");
        return 0;
        }
    if (mode == (u32)3)
        {
        fill(a, (u32)10);
        Stdio.printf("sum %u\n", sumFrom(a, (u32)4, (u32)7));
        return 0;
        }
    if (mode == (u32)4)
        {
        fill(a, (u32)10);
        Stdio.printf("grid %u\n", grid(a, (u32)3, (u32)4));
        return 0;
        }
    // A null pointer: the first index goes to the check.
    fill((u32*)0, (u32)3);
    return 0;
}
XC
for XC in ${XC:-bin/$PLAT/xcc-xc bin/$PLAT/xcc}; do
    [ -x "$XC" ] || continue
    for m in -fbounds-check=light -fbounds-check; do
        "$XC" -q -O2 $m -H . -o "$W/t" "$W/t.xc" > "$W/o" 2>&1 || { echo "FAIL $XC $m: build"; head -3 "$W/o"; fail=1; continue; }
        got=$("$W/t" 2>&1)
        [ "$got" = "$(printf 'ok 45 55 10\nfind 1\ncopy 0 39')" ] || { echo "FAIL $XC $m: in-bounds run gives '$got'"; fail=1; }
        expect() {
            local args=$1 want=$2 pre=$3
            "$W/t" $args > "$W/r" 2>&1; local rc=$?
            if [ $rc != 134 ] || ! grep -q "$want" "$W/r"; then
                echo "FAIL $XC $m: case '$args' (status $rc), wanted '$want'"; head -4 "$W/r"; fail=1
            elif [ -n "$pre" ] && [ "$(head -1 "$W/r")" != "$pre" ]; then
                echo "FAIL $XC $m: case '$args' did not run up to the failing access"; head -2 "$W/r"; fail=1
            elif grep -q '^after' "$W/r"; then
                echo "FAIL $XC $m: case '$args' ran on past the trap"; fail=1
            fi
        }
        # Checked.xc says "the array holds 10 elements"; the macOS debug
        # build's reporter "the allocation holds 10 elements of 4 bytes".
        expect "x" "index 10, but the" "before"
        expect "x y" "index 10, but the" ""
        expect "x y z" "index 10, but the" ""
        expect "x y z w" "at t.xc:6:" ""
        # Past the end of the destination: the checked copy of the loop runs.
        expect "x y z w v" "index 10, but the" ""
        if [ $m = -fbounds-check=light ]; then
            expect "x y z w" "index 0 through a null pointer" ""
        fi
    done
    # The light build hoists: the bound is computed, the check is still there.
    # Only the self-hosted compiler prints its optimised IR.
    case "$XC" in *xcc-xc) ;; *) continue ;; esac
    "$XC" -q -O2 -fbounds-check=light -H . --emit-ir-opt -o "$W/t" "$W/t.xc" 2> "$W/ir" || { echo "FAIL $XC: IR build"; fail=1; continue; }
    # In range, copyBytes runs an unchecked copy of its loop, which vectorises
    # as the unchecked build's does; the checked loop is still there.
    awk '/^  function copyBytes\(/,/^  }/' "$W/ir" > "$W/c.ir"
    grep -q 'Vec(' "$W/c.ir" || { echo "FAIL $XC: copyBytes' in-range loop does not vectorise"; fail=1; }
    grep -q 'Call @_xt_check_trap' "$W/c.ir" || { echo "FAIL $XC: copyBytes has no checked loop"; fail=1; }
    # The bound is computed ahead of every loop header (its phis) in fill, and
    # in grid ahead of the outer loop too.
    for f in fill grid; do
        awk "/^  function $f\\(/,/^  }/" "$W/ir" > "$W/f.ir"
        b=$(grep -n 'Call @_xt_check_limit' "$W/f.ir" | head -1 | cut -d: -f1)
        p=$(grep -n '= Phi' "$W/f.ir" | head -1 | cut -d: -f1)
        { [ -n "$b" ] && [ -n "$p" ] && [ "$b" -lt "$p" ]; } \
            || { echo "FAIL $XC: $f's bound is not computed before its loops"; fail=1; }
        grep -q 'Call @_xt_check_trap' "$W/f.ir" || { echo "FAIL $XC: $f has no check left"; fail=1; }
    done
done
# A loop that runs no times reads nothing: the bound is computed only when the
# loop is entered (the header's test again, before the loop). The pointer is
# the start of a page whose page before is unreadable, so reading its header
# faults; the program never reads it, and must not fault.
cat > "$W/z.xc" <<'XC'
#import "Foundation.xc"

pointer mmap(pointer addr, u64 len, i32 prot, i32 flags, i32 fd, i64 off);
i32 mprotect(pointer addr, u64 len, i32 prot);
i32 getpagesize(void);

u32 sumTo(u32* a, u32 n)
{
    u32 s = (u32)0;
    for (u32 i = (u32)0; i < n; i = i + (u32)1)
        s = s + a[i];
    return s;
}

i32 main(i32 argc, u8** argv)
{
    u64 page = (u64)getpagesize();
#if OS_macos
    i32 flags = (i32)$1002;
#else
    i32 flags = (i32)$22;
#endif
    u8* m = (u8*)mmap((pointer)0, page * (u64)2, (i32)3, flags, (i32)-1, (i64)0);
    mprotect((pointer)m, page, (i32)0);
    u32* p = (u32*)(pointer)(m + page);
    Stdio.printf("zero %u\n", sumTo(p, (u32)argc - (u32)1));
    return 0;
}
XC
for XC in ${XC:-bin/$PLAT/xcc-xc bin/$PLAT/xcc}; do
    [ -x "$XC" ] || continue
    for m in -fbounds-check=light -fbounds-check; do
        "$XC" -q -O2 $m -H . -o "$W/z" "$W/z.xc" > "$W/o" 2>&1 || { echo "FAIL $XC $m: zero-trip build"; head -3 "$W/o"; fail=1; continue; }
        got=$("$W/z" 2>&1); rc=$?
        { [ $rc = 0 ] && [ "$got" = "zero 0" ]; } || { echo "FAIL $XC $m: a loop that runs no times read its array's header (status $rc)"; fail=1; }
    done
done
[ $fail = 0 ] && echo "bounds-hoist: ok"
exit $fail
