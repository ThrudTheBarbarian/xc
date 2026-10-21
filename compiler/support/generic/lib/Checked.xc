// Checked.xc — the subscript checks of a checked build (-fbounds-check) on
// x86-64 and win64, imported by the compiler into such a build. arm64 macOS
// has its own reporter (rt-checked.c: a backtrace with arguments); here an
// out-of-range subscript is named by its site, its index and the extent, and
// the program stops with status 134, as an abort does.
//
// The compiler calls these before every subscript's address is used:
// _xt_check_bounds for a pointer (its heap block's header holds the count),
// _xt_check_bounds_n for a fixed-size array (a local or a global, whose count
// the compiler knows). Nothing here allocates or takes a lock, so a check is
// safe anywhere a subscript is, a par block's threads included.

i32 write(i32 fd, u8* buf, i32 len);   // as Stdio declares it
void _xt_exit(i32 code);

// The heap block header (rt.c, rt-freestanding.c): the magic at payload-40,
// the element stride after it, then the element count. A block of 64 KB and
// more is page-aligned and carries the second magic, with the same layout.
#define XT_CHECK_MAGIC $58544F42
#define XT_CHECK_MAGIC_ALIGNED $58544F43

void _xt_check_put(u8* s)
{
    u64 n = (u64)0;
    while (s[n] != (u8)0)
        n = n + (u64)1;
    write((i32)2, s, (i32)n);
}

void _xt_check_putNum(u64 v)
{
    u8 buf[24];
    u32 at = (u32)23;
    buf[at] = (u8)0;
    if (v == (u64)0)
        {
        at = at - (u32)1;
        buf[at] = (u8)'0';
        }
    while (v != (u64)0)
        {
        at = at - (u32)1;
        buf[at] = (u8)((u64)'0' + v % (u64)10);
        v = v / (u64)10;
        }
    _xt_check_put(&buf[at]);
}

void _xt_check_trap(u8* site, u64 index, u64 count, bool known)
{
    _xt_check_put("\n=== xcc: out-of-bounds access ===\n  at ");
    _xt_check_put(site != (u8*)0 ? site : "?");
    _xt_check_put("\n  index ");
    _xt_check_putNum(index);
    if (known)
        {
        _xt_check_put(", but the array holds ");
        _xt_check_putNum(count);
        _xt_check_put(count == (u64)1 ? " element\n" : " elements\n");
        }
    else
        _xt_check_put(" through a null pointer\n");
    _xt_check_put("  aborting\n");
    _xt_exit((i32)134);
}

// A raw pointer cast to a class: it must be null or a heap object, whose
// header carries the object magic; the class itself is then checked as a
// downcast from Object is.
void _xt_check_object(pointer ptr, u8* site)
{
    if (ptr == (pointer)0)
        return;
    if (*(u32*)(pointer)((u8*)ptr - 40) == (u32)XT_CHECK_MAGIC)
        return;
    _xt_check_put("\n=== xcc: a pointer cast to a class is not an object ===\n  at ");
    _xt_check_put(site != (u8*)0 ? site : "?");
    _xt_check_put("\n  aborting\n");
    _xt_exit((i32)134);
}

void _xt_check_bounds_n(pointer ptr, u64 index, u64 count, u8* site)
{
    if (index >= count)
        _xt_check_trap(site, index, count, true);
}

void _xt_check_bounds(pointer ptr, u64 index, u8* site)
{
    if (ptr == (pointer)0)
        {
        _xt_check_trap(site, index, (u64)0, false);
        return;
        }
    u8* h = (u8*)ptr - 40;
    u32 magic = *(u32*)(pointer)h;
    // Not a heap block (a pointer into a stack or global array, or into
    // memory C made): its extent is unknown, so nothing is checked.
    if (magic != (u32)XT_CHECK_MAGIC && magic != (u32)XT_CHECK_MAGIC_ALIGNED)
        return;
    u64 count = *(u64*)(pointer)(h + 12);
    if (index >= count)
        _xt_check_trap(site, index, count, true);
}
