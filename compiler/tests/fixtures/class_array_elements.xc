// class_array_elements.xc — reading, writing and CALLING METHODS on the
// elements of an inline class array (`new B[N]`).
//
// This was silently broken, and nothing caught it: heap_basic covers
// `new Tracker[6]` + `delete` (the per-element dealloc count) but never
// touches arr[i], and subscript_member covers arr[i].field only for
// STRUCT elements. Element ACCESS on a CLASS array had no coverage at all.
//
// `new B[N]` lays N instances out inline, so `bs[i]` has type B, not B@ —
// sema strips the pointer at the subscript. Lowering that as an expression
// yielded Load(ElementAddr(..)): it read the element's own first word and
// used it as a pointer to the instance. Field access then went through
// whatever that word held, and a method call was worse — a non-pointer
// class base that wasn't a value instance was classified as a STATIC call,
// so bs[i].set(..) compiled to a call with no `self` at all. No output, no
// diagnostic.
//
// Test surface:
//   T1  bs[i].field = v   through a dynamic index
//   T2  bs[i].field       read back, per element (each element distinct —
//                         the old bug made them all alias one address)
//   T3  bs[i].method()    instance call: self must be the ELEMENT
//   T4  bs[k].field       constant index
//   T5  a method that mutates self, seen through a later read

#import "Stdio.xc"

class Cell
{
    u16 v;
    u16 w;

    void bump(u16 by)  { self.v = self.v + by; }
    u16  sum(void)     { return self.v + self.w; }
}

i16 main(void)
{
    Cell* cs = new Cell[6];

    // T1: write both fields through a dynamic index.
    for (u16 i = 0; i < (u16)6; i = i + (u16)1)
    {
        cs[i].v = i + (u16)100;
        cs[i].w = i + (u16)200;
    }

    // T2: each element must be distinct — the old bug aliased them.
    for (u16 i = 0; i < (u16)6; i = i + (u16)1)
        Stdio.printf("%d/%d ", cs[i].v, cs[i].w);
    Stdio.printf("\n");

    // T3 + T5: an instance call whose self is the element, mutating it.
    for (u16 i = 0; i < (u16)6; i = i + (u16)1)
        cs[i].bump((u16)1000);
    for (u16 i = 0; i < (u16)6; i = i + (u16)1)
        Stdio.printf("%d ", cs[i].v);
    Stdio.printf("\n");

    // T3: a value-returning instance call, per element.
    for (u16 i = 0; i < (u16)6; i = i + (u16)1)
        Stdio.printf("%d ", cs[i].sum());
    Stdio.printf("\n");

    // T4: constant index reaches the same element as the dynamic one.
    Stdio.printf("k=%d %d %d\n", cs[0].v, cs[3].v, cs[5].sum());

    return 0;
}
