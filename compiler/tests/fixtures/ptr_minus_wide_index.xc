#use Stdio

// bug 39: `p - n` where n is 64 bits. The negated index was typed I16 whatever
// the index's real width, so `%n:I16 = Neg %idx:I64` reached the back ends:
// the arm64 in-house assembler refused it (`neg w10, x27` — w and x cannot be
// mixed) and the wasm writer asks the Neg RESULT's type to decide whether to
// `i32.wrap_i64`, so it skipped the wrap and handed an i64 to i32.sub.
//
// `p + n` has no Neg and always worked, so the offset here MUST be i64/u64 —
// an i32 or a bare literal passes vacuously.
//
// Distances are divided by sizeof(Rec) so the answer is in ELEMENTS and the
// expected output holds on every target: Rec is 16 bytes where a pointer is 8
// and 8 bytes where it is 4.
struct Rec { pointer next; pointer p; };
Rec gr[8];

u64 ad(pointer x) { return (u64)x; }

i32 main()
{
    Rec* e = &gr[5];
    u64  z = ad((pointer)e);
    u64  es = (u64)sizeof(Rec);

    i32 a = 3;  u32 b = (u32)3;  i64 c = (i64)3;  u64 d = (u64)3;

    printf("%ld\n", (i32)((z - ad((pointer)(e - a))) / es));
    printf("%ld\n", (i32)((z - ad((pointer)(e - b))) / es));
    printf("%ld\n", (i32)((z - ad((pointer)(e - c))) / es));
    printf("%ld\n", (i32)((z - ad((pointer)(e - d))) / es));
    printf("%ld\n", (i32)((z - ad((pointer)(e - 3))) / es));
    printf("%ld\n", (i32)((ad((pointer)(e + c)) - z) / es));
    return 0;
}
