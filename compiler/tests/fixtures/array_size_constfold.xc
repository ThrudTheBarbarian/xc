// Array bounds CONSTANT-FOLD (blewit item 4, Task #1080). `u8 buf[EVSZ *
// MAXEV]` used to be "Array size must be a compile-time integer literal"
// even with both macros literal — a parse-time token check that fired
// before any folder ran, though the parser already held the parsed
// expression. Bounds now fold literals through the arithmetic and bit
// operators (identifiers still refuse: the parser holds no symbol values).
// Every declarator position folds: global, ivar, local. (Parameters keep
// their existing shape — the reference grammar has no sized param arrays.)
#define EVSZ 12
#define MAXEV 64
#import "Stdio.xc"

u8 gbuf[EVSZ * MAXEV];

class Grid
{
    u8 cells[4 * (2 + 2)];

    static u16 mark(void)
    {
        Grid g;
        g.cells[(4 * (2 + 2)) - 1] = (u8)$DE;
        return (u16)g.cells[15];
    }
}

u16 sum(u8* vals)
{
    u16 t = (u16)0;
    for (u16 i = (u16)0; i < (u16)(2 * 8); i++) t = t + (u16)vals[i];
    return t;
}

i32 main(void)
{
    u8 local[1 << 4];
    for (u16 i = (u16)0; i < (u16)16; i++) local[i] = (u8)1;
    gbuf[(EVSZ * MAXEV) - 1] = (u8)$AD;
    Stdio.printf("g=%d sum=%d mark=%d\n",
                 (u16)gbuf[767], sum(local), Grid.mark());
    return 0;
}
