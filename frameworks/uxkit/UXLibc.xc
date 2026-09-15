// UXLibc.xc — the handful of libc calls the toolkit needs.
//
// Its own file so that a leaf like UXString does not have to #import the whole AES to
// get malloc.  That matters for more than tidiness: UXGeometry and UXString are PURE
// LOGIC, and keeping them free of <GEM> is what lets them be tested on the HOST — which
// is the only verification available while gemd is mid-build.
#if ARCH_wasm32
// wasm32 has NO libc: the one heap is the module's own coalescing free-list
// allocator (XTWasmBackend emitRuntimeInto), and a bodyless
// declaration binds to the generated runtime exactly as Heap.xc's
// _xtc_heap_* introspection does.  So libc's four are shims: stride 1 with a
// null dealloc descriptor is malloc-shaped (the payload arrives ZEROED, so
// calloc is the same call), _xtc_dealloc on a descriptorless block is free,
// and realloc learns the old block's usable length from the allocator's own
// total-size header word (base+32 = payload-6; layout documented at the
// emitter).  The refcount is 1 at birth and never touched — these blocks
// travel as `pointer`, never through ARC.
pointer _xtc_alloc(u32 count, u32 stride, u32 dealloc);
void _xtc_dealloc(pointer p);

pointer malloc(u32 n)
    {
    return _xtc_alloc(n, (u32)1, (u32)0);
    }
pointer calloc(u32 nmemb, u32 size)
    {
    return _xtc_alloc(nmemb, size, (u32)0);
    }
void free(pointer p)
    {
    if (p != (pointer)0)
        {
        _xtc_dealloc(p);
        }
    }
pointer realloc(pointer p, u32 n)
    {
    if (p == (pointer)0)
        {
        return _xtc_alloc(n, (u32)1, (u32)0);
        }
    u8* base = (u8*)p;
    u32 usable = ((u32*)(base - (u32)6))[0] - (u32)38;
    pointer np = _xtc_alloc(n, (u32)1, (u32)0);
    u8* d = (u8*)np;
    u32 m = usable < n ? usable : n;
    for (u32 i = (u32)0; i < m; i = i + (u32)1)
        {
        d[i] = base[i];
        }
    _xtc_dealloc(p);
    return np;
    }
#else
pointer malloc(u32 n);
pointer calloc(u32 nmemb, u32 size);
pointer realloc(pointer p, u32 n);
void free(pointer p);
#endif
