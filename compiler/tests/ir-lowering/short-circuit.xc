// short-circuit — && / || with short-circuit evaluation. All four
// paths are exercised inline (no nested calls, so the result is
// independent of the separate xt6502 ZP-scratch-across-calls issue):
//   &&  long  (LHS true  → eval RHS): 7>0 && 7<10  → true  (+1)
//   &&  short (LHS false → skip RHS): 0>0 && 0<10  → false (+0)
//   ||  short (LHS true  → skip RHS): 0==0 || 0>5  → true  (+4)
//   ||  long  (LHS false → eval RHS): 7==0 || 7>5  → true  (+8)
// sc() == 1 + 4 + 8 = 13.
u16 sc(void)
    {
    u16 a = (u16)7;
    u16 z = (u16)0;
    u16 r = (u16)0;
    if ((a > (u16)0) && (a < (u16)10))
        {
        r = r + (u16)1;
        }
    if ((z > (u16)0) && (z < (u16)10))
        {
        r = r + (u16)2;
        }
    if ((z == (u16)0) || (z > (u16)5))
        {
        r = r + (u16)4;
        }
    if ((a == (u16)0) || (a > (u16)5))
        {
        r = r + (u16)8;
        }
    return r;
    }
