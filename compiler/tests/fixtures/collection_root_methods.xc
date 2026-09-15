//xtc-flags: target=arm64
// The methods inherited from `Object` are NOT element positions — private:docs/bugs/055.
//
// Type arguments substitute positionally against what a signature erases to, so
// every `Object*` in the class was read as "one of my elements". That is right
// for `get`/`add`/`first`/`enumAt`, which the container declares, and wrong for
// the ones it inherits from the root: `equals(Object* other)` means "another
// object", not "an element of mine".
//
// The symptom was a FALSE REJECTION — and the tell was that dropping the
// annotation fixed it, i.e. the feature that exists to add safety removed a
// working operation:
//
//     Array*         p;  p.equals(q)   // compiled
//     Array<String>* a;  a.equals(b)   // error: 'Array.equals' element:
//                                      //        'Object' is not a subclass of 'String'
#import "Foundation.xc"
#import "Stdio.xc"

i32 main(void)
{
    Array<String>* a = new Array();
    Array<String>* b = new Array();
    a.add(String.withCString("x"));
    b.add(String.withCString("x"));

    // Inherited from Object: identity, and it must COMPILE on a typed array.
    // Two distinct arrays are not identical, so this is false — Array
    // deliberately keeps Object's identity `equals` (see Array.xc) and puts
    // value comparison under its own name.
    Stdio.printf("identity=%d\n", (u16)(a.equals((Object*)b) ? 1 : 0));

    // Value comparison takes `Array*` — the same type as the receiver, a real
    // type with nothing to erase — and works on a typed array.
    Stdio.printf("byValue=%d\n", (u16)(a.isEqualToArray(b) ? 1 : 0));

    // Also inherited, also not an element position.
    Stdio.printf("hashed=%d\n", (u16)(a.hash() != (u32)0 ? 1 : 0));

    // And the container's OWN erased positions still substitute and still
    // check — that is the half this must not break.
    String* first = a.get((u32)0);
    Stdio.printf("elem=%s count=%d\n", first.cString(), (u16)a.count());
    return 0;
}
