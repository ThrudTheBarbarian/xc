// callback_struct_stride.xc — bug 26 (c2xc). A struct field of `callback`
// type is an auto-zeroing weak slot laid out {pprev, next, payload} = 32 bytes
// on a 64-bit host, not the 16-byte bare pair. `sizeof` and the array-indexing
// STRIDE must agree on that expansion, or `base + i*sizeof(struct)` — how C
// walks a table — reads every element after the first from
// the wrong address.
//
// Five shapes, mixing scalars, pointers and one/two callbacks. For each the
// measured stride (&a[1]-&a[0]) must equal sizeof. A callback-free struct (S4)
// is the control: it agrees trivially and proves the harness isn't rigged.

#import "Foundation.xc"
#import "Stdio.xc"

struct S1 { i32 a; callback i32(i32 x) f; }
struct S2 { i32 a; u8* n; callback i32(i32 x) f; i32 b; }
struct S3 { u8* n; callback i32(i32 x) f; }
struct S4 { i32 a; u8* n; i32 b; }
struct S5 { i32 a; callback i32(i32 x) f; callback i32(i32 x) g; }

S1 a1[3]; S2 a2[3]; S3 a3[3]; S4 a4[3]; S5 a5[3];

i32 strideS1(void) { return (i32)((i64)(pointer)(&a1[1]) - (i64)(pointer)(&a1[0])); }
i32 strideS2(void) { return (i32)((i64)(pointer)(&a2[1]) - (i64)(pointer)(&a2[0])); }
i32 strideS3(void) { return (i32)((i64)(pointer)(&a3[1]) - (i64)(pointer)(&a3[0])); }
i32 strideS4(void) { return (i32)((i64)(pointer)(&a4[1]) - (i64)(pointer)(&a4[0])); }
i32 strideS5(void) { return (i32)((i64)(pointer)(&a5[1]) - (i64)(pointer)(&a5[0])); }

i32 main(void)
{
    i32 ok = (i32)0;
    if ((i32)sizeof(S1) == strideS1()) ok = ok + (i32)1;
    if ((i32)sizeof(S2) == strideS2()) ok = ok + (i32)1;
    if ((i32)sizeof(S3) == strideS3()) ok = ok + (i32)1;
    if ((i32)sizeof(S4) == strideS4()) ok = ok + (i32)1;
    if ((i32)sizeof(S5) == strideS5()) ok = ok + (i32)1;
    Stdio.printf("stride==sizeof for %d/5\n", ok);
    return (i32)0;
}
