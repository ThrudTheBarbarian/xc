// ptr-arith — pins the pointer-arithmetic lowering. `p + N` /
// `p - N` where p is a pointer route through ElementAddr (which
// the backend scales by sizeof(pointee) at emit time). The walk
// loop drives the @-deref + ptr-add combination through a real
// for-loop / while shape.
u8 strlen(u8* s)
    {
    u8 n = 0;
    while (*s != 0)
        {
        s = s + 1;
        n = n + 1;
        }
    return n;
    }
