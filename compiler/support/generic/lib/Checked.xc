// Checked.xc — the subscript checks of -fbounds-check=light (arm64 macOS,
// x86-64, win64) and of -fbounds-check on x86-64 and win64, imported by the
// compiler into such a build. An out-of-range subscript is named by its site,
// its index and the extent, and the program stops with status 134, as an
// abort does. -fbounds-check on arm64 macOS links rt-checked's reporter
// instead (a backtrace with arguments, every frame kept for it).
//
// The compiler calls these before every subscript's address is used:
// _xt_check_bounds for a pointer (its heap block's header holds the count),
// _xt_check_bounds_n for a fixed-size array (a local or a global, whose count
// the compiler knows). Nothing here allocates or takes a lock, so a check is
// safe anywhere a subscript is, a par block's threads included.

i32 write(i32 fd, u8* buf, i32 len);   // as Stdio declares it
void _xt_exit(i32 code);

// The heap block header (rt.c, rt-freestanding.c): the magic at payload-8,
// next to the refcount; an array's element count at payload-32. A block of
// 64 KB and more is page-aligned and carries the second magic, with the same
// layout.
#define XT_CHECK_MAGIC $58544F42
#define XT_CHECK_MAGIC_ALIGNED $58544F43
#define XT_CHECK_MAGIC_OBJW $58544F4F

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

void _xt_check_cast_trap(u8* site)
{
    _xt_check_put("\n=== xcc: a pointer cast to a class is not an object ===\n  at ");
    _xt_check_put(site != (u8*)0 ? site : "?");
    _xt_check_put("\n  aborting\n");
    _xt_exit((i32)134);
}

// A raw pointer cast to a class: it must be null or a heap object, whose
// header carries the object magic; the class itself is then checked as a
// downcast from Object is.
void _xt_check_object(pointer ptr, u8* site)
{
    // One return and no merged values: the inliner takes a check whose only
    // call is the trap, so a check costs a compare where it is used.
    if (ptr != (pointer)0)
        {
        // A class instance (magic XTON, or XTOO once a weak reference has
        // pointed at it: they differ in bit 0) or an array block.
        u32 m = *(u32*)(pointer)((u8*)ptr - 8);
        if ((m | (u32)1) != (u32)XT_CHECK_MAGIC_OBJW)
            {
            if (m != (u32)XT_CHECK_MAGIC)
                _xt_check_cast_trap(site);
            }
        }
}

void _xt_check_bounds_n(pointer ptr, u64 index, u64 count, u8* site)
{
    if (index >= count)
        _xt_check_trap(site, index, count, true);
}

#if XT_CHECK_FULL
// The runtime's table of array blocks (rt.c, rt-freestanding.c).
void _xtc_block_note(pointer p);
pointer _xtc_block_find(pointer p);

// A pointer with no header in front of it, in the debug build: if it points
// into a block a check has seen, check it there, as an index from the block's
// start in the block's own elements. A pointer it cannot place (on the stack,
// in a global, in memory C made, or into a block no check has seen) is not
// checked.
void _xt_check_interior(pointer ptr, u64 index, u8* site)
{
    u8* s = (u8*)_xtc_block_find(ptr);
    if (s == (u8*)0)
        return;
    u8* h = s - 40;
    u32 magic = *(u32*)(pointer)(h + 32);
    u64 stride = *(u64*)(pointer)h;
    if ((magic | (u32)1) != (u32)XT_CHECK_MAGIC_ALIGNED || stride == (u64)0)
        return;
    u64 off = (u64)((u8*)ptr - s);
    if (off % stride != (u64)0)
        return;
    u64 at = off / stride + index;
    if (at >= *(u64*)(pointer)(h + 8))
        _xt_check_trap(site, at, *(u64*)(pointer)(h + 8), true);
}
#endif

// The bound a loop's checks on ptr compare against, computed once before the
// loop when nothing in it can change ptr's block header (the optimiser's
// bounds-hoist): the loop calls _xt_check_bounds only for an index at or past
// it. 0 for a null pointer, so every index goes to the check, which reports
// the null; a block's count; for any other pointer the most there is under
// -fbounds-check=light, which checks nothing there, and 0 in the debug build,
// whose check looks the pointer up.
u64 _xt_check_limit(pointer ptr)
{
    u64 lim = (u64)0;
    if (ptr != (pointer)0)
        {
        u8* h = (u8*)ptr - 40;
        u32 magic = *(u32*)(pointer)(h + 32);
        if ((magic | (u32)1) == (u32)XT_CHECK_MAGIC_ALIGNED)
            {
#if XT_CHECK_FULL
            _xtc_block_note(ptr);
#endif
            lim = *(u64*)(pointer)(h + 8);
            }
#if XT_CHECK_FULL
#else
        else
            lim = (u64)0 - (u64)1;
#endif
        }
    return lim;
}

void _xt_check_bounds(pointer ptr, u64 index, u8* site)
{
    if (ptr == (pointer)0)
        _xt_check_trap(site, index, (u64)0, false);
    else
        {
        // Not a block's start (a pointer into a stack or global array, into
        // memory C made, or into the middle of a block): -fbounds-check=light
        // checks nothing, the debug build looks it up.
        u8* h = (u8*)ptr - 40;
        u32 magic = *(u32*)(pointer)(h + 32);
        // The two magics differ only in bit 0: one compare, and no merge.
        if ((magic | (u32)1) == (u32)XT_CHECK_MAGIC_ALIGNED)
            {
#if XT_CHECK_FULL
            _xtc_block_note(ptr);
#endif
            if (index >= *(u64*)(pointer)(h + 8))
                _xt_check_trap(site, index, *(u64*)(pointer)(h + 8), true);
            }
#if XT_CHECK_FULL
        else
            _xt_check_interior(ptr, index, site);
#endif
        }
}
