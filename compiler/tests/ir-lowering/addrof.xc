// addrof — pins the AddrOf-of-local lowering. The pre-scan
// detects `&x` and pins x at function entry; subsequent reads
// of x go through AddrOf + Load on the pinned slot, writes
// go through AddrOf + Store. The aliased-write pattern via
// the pointer is the observable consequence: setting *p = 99
// changes what `return x` reads.
u8 aliased(void)
    {
    u8 x = 10;
    u8* p = &x;
    *p = 99;
    return x;
    }
