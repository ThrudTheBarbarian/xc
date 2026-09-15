// byte-list-const-fold — byte-list entries that const-fold (char
// literals, constant integer expressions) assemble into a single Const,
// the same fast path plain integer literals take — no per-byte stores
// and no pinning (task #61). Goldens here show the Const result, not
// element-wise stores.
//
// chars: 'A'=$41, 'B'=$42 → little-endian u16 = $4241 = 16961.
// expr:  1+1=2, (1<<4)|1=$11, $00, $80 → little-endian u32 = $80001102.
u16 chars(void)
    {
    u16 v = {'A', 'B'};
    return v;
    }

u32 expr(void)
    {
    u32 v = {1 + 1, (1 << 4) | 1, $00, $80};
    return v;
    }
