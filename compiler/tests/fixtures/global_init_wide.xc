// global_init_wide.xc — 64-bit global initialisers keep all eight bytes.
//
// A global's initial value is folded at compile time into little-endian
// bytes. The shipped compiler folded it through a 32-bit value, so
// `u64 g = 0x199999999999999A;` came out as 0x9999999A on every target, and
// `0x80000000 >> 4` shifted a negative 32-bit value. It also encoded a float
// literal in a `double` global at double precision, where the same literal
// in code has float precision, and it did not fold a static local or static
// ivar that was not an integer. On m68k the eight bytes of an i64 or u64
// were left in little-endian order, which is backwards on a big-endian
// machine (both compilers).
//
// Each global is printed next to the same value computed at run time, so a
// target with the wrong image disagrees with itself.
#import "Stdio.xc"

struct Wide { u8 tag; i64 big; u64 ubig; double d; u16 tail; }

u64    gU    = 0x199999999999999A;
u64    gUc   = (u64)0x0123456789ABCDEF;
i64    gI    = -81985529216486895;
i64    gMin  = -9223372036854775807 - 1;
u64    gMax  = 0xFFFFFFFFFFFFFFFF;
double gD    = 3.1;
double gDd   = 3.1d;
float  gF    = 3.1;
u64    gExpr = (1 << 40) | 5;
u32    gShr  = 0x80000000 >> 4;
u64    gArr[3] = { 0x1122334455667788, 2, 0x8000000000000001 };
i64    gIArr[2] = { -2, 0x7FFFFFFFFFFFFFFF };
double gDArr[2] = { 3.1, -0.1 };
Wide   gS    = { $5A, -1234567890123, 0xFEDCBA9876543210, 2.2, $BEEF };
u8     gGuard = $DE;

class Holder
{
    static u64 kept = 0x0F0E0D0C0B0A0908;
    static double ratio = 3.1;
    static u64 value(void) { return kept; }
    static double r(void) { return ratio; }
}

u64 staticWide(void)
{
    static u64 s = 0x0102030405060708;
    return s;
}

double staticDouble(void)
{
    static double sd = 3.1;
    return sd;
}

void line(string name, u64 have, u64 want)
{
    Stdio.printf("%s %s %s\n", name, String.withU64(have).cString(),
                 have == want ? "ok" : "WRONG");
}

u64 bitsOf(double d)
{
    double v = d;
    u64* p = (u64*)&v;
    return *p;
}

void main(void)
{
    line("gU", gU, (u64)0x19999999 << (u64)32 | (u64)0x9999999A);
    line("gUc", gUc, (u64)0x01234567 << (u64)32 | (u64)0x89ABCDEF);
    line("gI", (u64)gI, (u64)((i64)0 - (i64)81985529216486895));
    line("gMin", (u64)gMin, (u64)1 << (u64)63);
    line("gMax", gMax, (u64)0 - (u64)1);
    line("gD", bitsOf(gD), bitsOf(3.1));
    line("gDd", bitsOf(gDd), bitsOf(3.1d));
    Stdio.printf("gF %s\n", gF == (float)3.1 ? "ok" : "WRONG");
    line("gExpr", gExpr, ((u64)1 << (u64)40) + (u64)5);
    line("gShr", (u64)gShr, (u64)$08000000);
    line("gArr0", gArr[0], (u64)0x11223344 << (u64)32 | (u64)0x55667788);
    line("gArr1", gArr[1], (u64)2);
    line("gArr2", gArr[2], ((u64)1 << (u64)63) + (u64)1);
    line("gIArr0", (u64)gIArr[0], (u64)0 - (u64)2);
    line("gIArr1", (u64)gIArr[1], ((u64)1 << (u64)63) - (u64)1);
    line("gDArr0", bitsOf(gDArr[0]), bitsOf(3.1));
    line("gDArr1", bitsOf(gDArr[1]), bitsOf(-0.1));
    line("gS.tag", (u64)gS.tag, (u64)$5A);
    line("gS.big", (u64)gS.big, (u64)((i64)0 - (i64)1234567890123));
    line("gS.ubig", gS.ubig, (u64)0xFEDCBA98 << (u64)32 | (u64)0x76543210);
    line("gS.d", bitsOf(gS.d), bitsOf(2.2));
    line("gS.tail", (u64)gS.tail, (u64)$BEEF);
    line("kept", Holder.value(), (u64)0x0F0E0D0C << (u64)32 | (u64)0x0B0A0908);
    line("ratio", bitsOf(Holder.r()), bitsOf(3.1));
    line("staticWide", staticWide(), (u64)0x01020304 << (u64)32 | (u64)0x05060708);
    line("staticDouble", bitsOf(staticDouble()), bitsOf(3.1));
    line("guard", (u64)gGuard, (u64)$DE);
}
