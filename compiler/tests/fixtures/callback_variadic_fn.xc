// Bug 165c — taking the address of a VARIADIC FUNCTION as a bound method. A `^`
// is a fixed-arity pair whatever the callee's arity, so `&emit` (emit variadic)
// and `&plain` (non-variadic, same fixed params) must share ONE trampoline and
// compare EQUAL through the same callback type — and the trampoline name must
// not carry the callee's `...` (the reference used to, diverging from the port).
i32 printf(u8* fmt, ...);

void emit(u8* a0, ...) { printf("emit %s\n", a0); }
void plain(u8* a0)     { printf("plain %s\n", a0); }

callback void(u8*) pick(i32 which) { return which != 0 ? &emit : &plain; }

i32 main(void) {
    callback void(u8*) a = &emit;    // widen a VARIADIC function
    callback void(u8*) b = &emit;    // same function, same callback type
    if (a) a("x");                   // call through the bound pair
    // Two `^`s naming the same action must be equal (shared trampoline).
    printf("eq=%d\n", a == b ? 1 : 0);
    callback void(u8*) p = pick(0);  // a non-variadic function through the same type
    if (p) p("y");
    return 0;
}
