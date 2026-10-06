//xtc-flags: target=arm64, -Wno-covariant-return
// Suggest a covariant return where a method declares the type it INHERITED.
//
// `Object* copy(void)` on a container is legal and compiles, but it throws away
// what the body knows — and because type arguments substitute positionally
// against erased spellings, an inherited `Object*` on a class used with a type
// argument is read as "one of my elements". That is how private:docs/bugs/051 typed an
// Array as a String, silently.
//
// Returns are COVARIANT, so the fix is one word at the declaration. The library
// already does it (`Array* copy(void)`), which is why this fixture has to bring
// its own class: nothing shipped still has the shape.
//
// The warning is gated on the class being USED with a type argument, since that
// is where the mistyping happens; without the gate every `Object* copy` in the
// program would report. It is switchable: -Wno-covariant-return.
//xtc-flags: -Wno-covariant-return
#import "Foundation.xc"
#import "Copying.xc"
#import "Stdio.xc"

class Satchel : Object <Copying>
{
    Object* one;
    void init(void) { one = (Object*)0; }
    void put(Object* o) { one = o; }
    // NOT flagged: this really does return "some object", and the body says so.
    Object* get(void) { return one; }
    // Flagged: every return is a Satchel, so it could declare `Satchel*`.
    Object* copy(void) { Satchel* b = new Satchel(); b.one = one; return (Object*)b; }
}

i32 main(void)
{
    // The ANNOTATED use is what arms the warning — the class is being used with
    // a type argument, which is where an inherited `Object*` return misleads.
    Satchel<String>* b = new Satchel();
    b.put(String.withCString("x"));
    String* got = b.get();          // `get` really does return "some object"
    Stdio.printf("got=%s\n", got.cString());

    // copy() is called through a PLAIN Satchel*, because on the annotated one it
    // would substitute to `String*` — which is the mistyping the warning is
    // telling the author to prevent by declaring `Satchel* copy(void)`.
    Satchel* plain = new Satchel();
    Satchel* c = (Satchel*)plain.copy();
    Stdio.printf("copied=%d\n", (u16)(c != 0 ? 1 : 0));
    return 0;
}
