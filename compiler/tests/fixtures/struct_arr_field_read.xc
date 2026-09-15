// struct_arr_field_read.xc — `arr[i].field` read projection.
//
// Before this landing the member-access codegen hit a fallback
// path when the base of `.field` was a subscript expression.
// The fallback evaluated `arr[i]` via emitExprToA — which loads
// bytes 0..1 of the element — and silently dropped the field
// offset from the flatten loop. Every scalar-field read on a
// stack struct array returned the element's first two bytes
// regardless of which field was named.
//
// This fixture verifies the fix for the three shapes the new
// branch handles:
//   • Constant index, ZP-resident array base — folds to an
//     absolute LDA at `arr_base + idx*elemWidth + field_off`.
//   • Constant index, spilled array base — same address math
//     via a `label+offset` form.
//   • Dynamic index — `emitSubscriptAddrToZp` computes the
//     element address into `zpTmp`, then `(zpTmp),Y` applies
//     the field offset.
//
// Covers u8 / u16 / u32 field widths. Pointer fields are not
// exercised here (they route through the existing member-load
// path for class storage).

#import "Stdio.xc"
#import "Assert.xc"

struct Cell
{
    u16 a;
    u16 b;
    u32 c;
    u8  tag;
}

void main(void)
{
    Assert.reset();

    Cell arr[4];
    arr[0].a = 10; arr[0].b = 20; arr[0].c = 100000; arr[0].tag = 1;
    arr[1].a = 11; arr[1].b = 21; arr[1].c = 200000; arr[1].tag = 2;
    arr[2].a = 12; arr[2].b = 22; arr[2].c = 300000; arr[2].tag = 3;
    arr[3].a = 13; arr[3].b = 23; arr[3].c = 400000; arr[3].tag = 4;

    // ── T1-T4: constant index, every field width ─────────────
    Assert.isEqual(arr[0].a, 10);                     // T1
    Assert.isEqual(arr[1].b, 21);                     // T2
    Assert.isEqual(arr[2].c, 300000);                 // T3
    Assert.isEqual((u16)arr[3].tag, 4);               // T4

    // ── T5-T9: dynamic index through zpTmp path ──────────────
    u16 i;
    i = 2;
    Assert.isEqual(arr[i].a, 12);                     // T5
    Assert.isEqual(arr[i].b, 22);                     // T6
    Assert.isEqual(arr[i].c, 300000);                 // T7
    i = 3;
    Assert.isEqual(arr[i].a, 13);                     // T8
    Assert.isEqual((u16)arr[i].tag, 4);               // T9

    Assert.summary();
    return;
}
