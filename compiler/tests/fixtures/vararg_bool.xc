// vararg_bool.xc — default-argument promotion of a bool vararg.
//
// packVarargsFrom widens a narrow integer vararg to 2 bytes before storing it
// into __xtc_va_buf, because `%d` / `%u` read the slot 16 bits wide. Bool was
// missing from that promotion (XTIRTypeKindIsInteger excludes it), so a bool
// was stored as a single byte and the other half of the slot was whatever the
// previous call left there:
//
//   - little-endian: `printf("%d", a == b)` after a call that parked $BEEF in
//     the slot printed -16895 ($BE01) — the stale high byte leaked in;
//   - big-endian m68k: it printed 256, because the one live byte IS the high
//     half of the 16 bits `%d` reads.
//
// The first line deliberately primes the slot with a non-zero value, so a
// regression can't hide behind an already-zeroed buffer.
#import "Stdio.xc"

u16 prime = $BEEF;
u16 a     = 5;
u16 b     = 5;
u8* nul   = 0;

void main()
{
    Stdio.printf("prime=%x\n", prime);       // park $BEEF in vararg slot 0
    Stdio.printf("eq=%d ne=%d\n", a == b, a != b);
    bool t = (a == b);
    bool f = (a != b);
    Stdio.printf("t=%d f=%d\n", t, f);
    Stdio.printf("null=%d\n", nul == 0);
}
