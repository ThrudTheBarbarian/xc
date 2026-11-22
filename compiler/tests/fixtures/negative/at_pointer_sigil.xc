// `@` is no longer a pointer sigil (#549): `*` is the only spelling.
// xtc: error "'@' is no longer a pointer sigil: use * for pointers"
i32 main(void)
    {
    u32 x = (u32)5;
    u32@ p = &x;
    return (i32)0;
    }
