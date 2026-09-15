// weak_on_scalar.xc — `weak:` rejected on non-class pointer pointees.
//
// The weak-reference side table keys on heap-block addresses, and
// non-class pointers (u8@, i16@, etc.) don't own heap blocks with
// refcount headers. Only class pointers are valid weak targets.
//
// xtc: error "`weak:` requires a class pointer"

u8 main() {
    weak:u8* p = (u8*)0;
    return (u8)0;
}
