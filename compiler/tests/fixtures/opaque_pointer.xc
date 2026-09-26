// Opaque pointer types (C's incomplete-type idiom): `iop` is never defined and
// is used only through `iop*` — a struct field, function params/returns, and
// casts. c2xc emits exactly this shape for external handles.
// An opaque pointer is a plain pointer-sized handle (Ptr(Void)); it is never
// dereferenced in xc. Both compilers must accept it and agree byte-for-byte.
// (An opaque LOCAL `iop* p;` stays unsupported — ambiguous with a multiply —
// so every opaque value here is a field, a parameter, a return, or a cast.)
#import "Stdio.xc"

struct Handle { i32 tag; iop* raw; }

iop* wrap(iop* p) { return (iop*)p; }              // opaque param + return + cast
void put(Handle* h, iop* p) { h.raw = (iop*)p; }   // opaque field store via cast
i32  tag_of(Handle* h) { return h.tag; }

i32 main(void) {
    Handle h;
    h.tag = 7;
    // a sentinel address carried through param/return/cast into an opaque field
    put(&h, wrap((iop*)0x1234));
    // read it back out and prove the handle round-trips unchanged
    Stdio.printf("%d %d\n", tag_of(&h), (i32)((u32)h.raw));
    return 0;
}
