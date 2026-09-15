// Natural struct field alignment (blewit #5, the complement of Task #1081's
// `:packed`). Default structs lay out as the TARGET's C ABI would: each field
// at the next offset aligned to min(its natural alignment, the target's cap),
// sizeof tail-rounded to the struct's alignment. On arm64 that cap is 8, so
// this struct matches clang's layout exactly — which is the whole point:
// naturally-padded C structs (llhttp_t, struct timespec, ...) are declarable
// in xtc verbatim, with no explicit __pad fields.
//
// The offsets below are ARM64's (cap 8); xt6502 still packs tightly (cap 1),
// so this fixture is arm64-only. `:packed` remains the cross-target-identical
// layout — struct_packed.xc guards that side.
//xtc-flags: target=arm64
#use Stdio

struct Probe
{
    u8     a;    // @0
    u32    b;    // @4  (C: aligned to 4; packed would say 1)
    u8     c;    // @8
    double d;    // @16 (C: aligned to 8; packed would say 9)
    u8*    e;    // @24
}                // sizeof 32 (end 32, aligned 8)

struct Inner  { u8 tag; u32 v; }        // v @4, sizeof 8
struct Outer  { u8 k; Inner inr; u8 t; } // inr @4 (aligns to Inner's 4), t @12, sizeof 16

i32 main()
{
    Probe p;
    printf("b=%d c=%d d=%d e=%d size=%d\n",
        (i32)((u64)&p.b - (u64)&p.a), (i32)((u64)&p.c - (u64)&p.a),
        (i32)((u64)&p.d - (u64)&p.a), (i32)((u64)&p.e - (u64)&p.a),
        (i32)sizeof(Probe));

    Outer o;
    printf("inr=%d t=%d osize=%d\n",
        (i32)((u64)&o.inr - (u64)&o.k), (i32)((u64)&o.t - (u64)&o.k),
        (i32)sizeof(Outer));

    // Array-stride probe: a wrong sizeof cannot survive this. Element 1's
    // fields must land exactly one padded stride past element 0's.
    Probe arr[2];
    arr[0].b = 100; arr[0].d = 1.5;
    arr[1].b = 200; arr[1].d = 2.5;
    printf("stride=%d b0=%ld b1=%ld\n",
        (i32)((u64)&arr[1] - (u64)&arr[0]), arr[0].b, arr[1].b);
    return 0;
}
