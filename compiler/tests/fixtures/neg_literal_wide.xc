// A negated integer literal whose value needs a wider type than the literal.
//
// `-3000000000` types its operand u32 and the negation i64 (the narrowest
// signed type that holds the negated value). The lowering negated the u32
// Const straight into an I64, so the Neg's operand was narrower than its
// result: arm64 emitted `neg xN, wM`, which does not assemble, and arm9 at -O2
// read eight bytes from a four-byte slot. Every width is covered, with and
// without a cast, through calls so nothing folds the value away.
#import "Foundation.xc"
#import "Stdio.xc"

i64 id64(i64 v) { return v; }
u64 idu64(u64 v) { return v; }
i32 id32(i32 v) { return v; }
i16 id16(i16 v) { return v; }
i8 id8(i8 v) { return v; }

void p(i64 v) { Stdio.printf("%s\n", String.withI64(v).cString()); }

void main(void)
{
    p(id64((i64)-3000000000));
    p(id64(-3000000000));
    p(id64((i64)-5000000000));
    p(id64((i64)-4294967295));
    p(id64((i64)-200));
    p(id64((i64)-40000));
    p(id64((i64)-1));
    p((i64)id32((i32)-40000));
    p((i64)id32(-2147483648));
    p((i64)id16((i16)-200));
    p((i64)id16(-32768));
    p((i64)id8((i8)-128));
    p((i64)id8(-1));
    i64 a = -3000000000;
    i32 b = -40000;
    i16 c = -200;
    p(id64(a));
    p((i64)id32(b));
    p((i64)id16(c));
    Stdio.printf("%s\n", String.withU64(idu64((u64)-3000000000)).cString());
    p(id64((i64)~3000000000));
    p(id64((i64)~200));
    bool z = !3000000000;
    p(id64(z ? (i64)1 : (i64)0));
    p(id64(-(i64)3000000000));
}
