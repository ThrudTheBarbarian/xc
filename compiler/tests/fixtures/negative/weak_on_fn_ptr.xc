// weak_on_fn_ptr.xc — `weak:` rejected on function pointers.
//
// Function pointers don't have ARC refcount headers either, so
// `weak:` is nonsensical here. This fixture pins the pointee-kind
// check down to function types specifically; a generic u8@ case
// lives in weak_on_scalar.xc.
//
// xtc: error "`weak:` requires a class pointer"

typedef u8 op_t(u8);

u8 main() {
    weak:op_t* fn = (op_t*)0;
    return (u8)0;
}
