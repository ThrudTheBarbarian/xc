// valist.xc — regression coverage for the va_list / va_arg_* /
// va_end intrinsics on a user-declared varargs function.
//
// Exercises every scalar va_arg_* width: u8, i8, u16, i16, u32,
// i32, float, double, string, ptr. The variadic function stashes
// each pulled value into a global so main can cross-check against
// the literals it passed.

#import "Stdio.xc"

u8  r_u8;   i8  r_i8;
u16 r_u16;  i16 r_i16;
u32 r_u32;  i32 r_i32;
float  r_f;
double r_d;
string r_s;
u8*    r_p;

u8 sentinel;

void checker(string tag, ...)
{
    u8 ap;
    va_start(ap);
    r_u8  = va_arg(ap, u8);
    r_i8  = va_arg(ap, i8);
    r_u16 = va_arg(ap, u16);
    r_i16 = va_arg(ap, i16);
    r_u32 = va_arg(ap, u32);
    r_i32 = va_arg(ap, i32);
    r_f   = va_arg(ap, float);
    r_d   = va_arg(ap, double);
    r_s   = va_arg(ap, string);
    r_p   = va_arg(ap, u8*);
    va_end(ap);
}

u8 testCount;
u8 failCount;

void check(u8 n, u8 ok)
{
    testCount = testCount + 1;
    if (!ok) {
        failCount = failCount + 1;
        Stdio.printf("T%u FAIL\n", n);
    }
}

void main(void)
{
    sentinel = 99;
    u8* ptrArg = &sentinel;

    checker("probe",
        (u8)200, (i8)-7,
        (u16)1234, (i16)-1000,
        (u32)100000, (i32)-100000,
        2.5, 1.5d,
        "hello", ptrArg);

    check(1,  r_u8  == 200);
    check(2,  r_i8  == -7);
    check(3,  r_u16 == 1234);
    check(4,  r_i16 == -1000);
    check(5,  r_u32 == 100000);
    check(6,  r_i32 == -100000);
    check(7,  r_f == 2.5);
    check(8,  r_d == 1.5d);
    // r_s points to a string constant with contents "hello".
    check(9,  *r_s == $68 && *(r_s+1) == $65);
    // r_p points to the sentinel byte.
    check(10, *r_p == 99);

    Stdio.printf("DONE %u\n", testCount);
}
