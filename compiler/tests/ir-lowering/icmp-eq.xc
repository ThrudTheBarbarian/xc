// icmp-eq — equality/relational comparisons materialised to a 0/1
// boolean. xt6502 derived the bool by loading A *before* the
// flag-testing branch, which cleared Z and broke every Z-testing
// predicate (EQ/NE, and the a==b case of UGT/ULE); only the
// carry-testing ULT/UGE survived. cmp(7) exercises all four:
//   7 == 5 → false (0)   7 != 5 → true  (+2)
//   7 >  5 → true (+4)   7 <= 5 → false (0)   ⇒ 6
u16 cmp(u16 n)
    {
    u16 r = (u16)0;
    if (n == (u16)5)
        {
        r = r + (u16)1;
        }
    if (n != (u16)5)
        {
        r = r + (u16)2;
        }
    if (n > (u16)5)
        {
        r = r + (u16)4;
        }
    if (n <= (u16)5)
        {
        r = r + (u16)8;
        }
    return r;
    }
