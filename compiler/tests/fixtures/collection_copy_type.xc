//xtc-flags: target=arm64, expect=sema-error
// NOT xt6502: it has its own smaller Array.xc with no `copy` at all, so this
// would fail there for an unrelated reason ("No method 'copy' on class
// 'Array'") and prove nothing about the TYPE of copy, which is what it tests.
// `copy()` returns the COLLECTION, not one of its elements — private:docs/bugs/051.
//
// Typed collections work by ERASURE: a container spells its element `Object*`
// and sema substitutes the declared element type back in at the call site. That
// convention collides with `Copying`, which declares `Object* copy(void)` — so a
// collection's own copy is spelled exactly like one of its elements.
//
// Before this was excluded, the line below compiled with NO diagnostic: an
// Array was accepted wherever a String belonged, and `s.length()` answered with
// the array's element count. Luck of the layout; anything reaching further into
// the object is arbitrary memory.
#import "Foundation.xc"
#import "Stdio.xc"

i32 main(void)
{
    Array<String>* a = new Array();
    a.add(String.withCString("hi"));
    String* s = a.copy();                 // an Array typed as a String*
    Stdio.printf("len=%d\n", s.byteLength());
    return 0;
}
