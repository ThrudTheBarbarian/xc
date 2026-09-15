//xtc-flags: target=arm64
// NOT xt6502: it has its own smaller Array.xc with no `copy` at all, so this
// would fail there for an unrelated reason ("No method 'copy' on class
// 'Array'") and prove nothing about the TYPE of copy, which is what it tests.
// The positive half of collection_copy_type.xc — the spellings that must keep
// working after `copy` was excluded from element substitution (private:docs/bugs/051).
// An element READ still substitutes; only `copy` needs the collection's type.
#import "Foundation.xc"
#import "Stdio.xc"
i32 main(void)
{
    Array<String>* a = new Array();
    a.add(String.withCString("hi"));
    a.add(String.withCString("there"));

    // The element read still substitutes — that is the whole point of 046/typed
    // collections and must be untouched by the copy exclusion.
    String* first = a.get((u32)0);
    Stdio.printf("first=%s count=%d\n", first.cString(), (u16)a.count());

    // copy() returns the COLLECTION, so it needs the collection's type.
    // copy() DECLARES `Array*` (returns are covariant, so it need not inherit
    // `Copying`'s `Object*`), so this needs no cast at all.
    Array* b = a.copy();
    Stdio.printf("copy count=%d elem=%s\n", (u16)b.count(), ((String*)b.get((u32)1)).cString());
    return 0;
}
