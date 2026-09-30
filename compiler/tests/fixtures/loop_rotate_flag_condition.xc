// A loop whose condition is a flag carried round it (`while (again)`), with
// branches in its body: the unsigned magic-number search from the x86-64
// back end. Rotation must leave it alone — there is no guard instruction to
// copy to the bottom — and at -O2 it computed the wrong magic (or never ended).
#use Stdio

void magicU(u32 d, u32* mOut, u32* sOut)
    {
    u32 twoWm1 = (u32)1 << (u32)31;
    u32 maxu = (u32)$FFFF_FFFF;
    u32 p = (u32)31;
    u32 nc = maxu - ((maxu % d) + (u32)1) % d;
    u32 q1 = twoWm1 / nc;
    u32 r1 = twoWm1 - q1 * nc;
    u32 q2 = (twoWm1 - (u32)1) / d;
    u32 r2 = (twoWm1 - (u32)1) - q2 * d;
    bool again = true;
    while (again)
        {
        p = p + (u32)1;
        if (r1 >= nc - r1)
            {
            q1 = q1 + q1 + (u32)1;
            r1 = r1 - (nc - r1);
            }
        else
            {
            q1 = q1 + q1;
            r1 = r1 + r1;
            }
        if (r2 + (u32)1 >= d - r2)
            {
            q2 = q2 + q2 + (u32)1;
            r2 = r2 - (d - r2 - (u32)1);
            }
        else
            {
            q2 = q2 + q2;
            r2 = r2 + r2 + (u32)1;
            }
        u32 delta = d - (u32)1 - r2;
        again = p < (u32)64 && (q1 < delta || (q1 == delta && r1 == (u32)0));
        }
    *mOut = q2 + (u32)1;
    *sOut = p - (u32)32;
    }

i32 main(void)
    {
    u32 m = (u32)0;
    u32 s = (u32)0;
    magicU((u32)10, &m, &s);
    Stdio.printf("%lu %lu\n", m, s);
    magicU((u32)7, &m, &s);
    Stdio.printf("%lu %lu\n", m, s);
    return 0;
    }
