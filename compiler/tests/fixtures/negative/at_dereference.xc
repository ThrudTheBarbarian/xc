// Prefix `@` is no longer a dereference (#549): `*p` reads through a pointer.
// xtc: error "'@' is no longer a pointer sigil: use * for pointers"
i32 main(void)
    {
    u32 x = (u32)5;
    u32* p = &x;
    return (i32)@p;
    }
