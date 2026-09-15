//xtc-flags: expect=sema-error
// callback_to_cabi_refused.xc — bug 165d (c2xc). A `callback` is a two-word
// {recv, code} pair; a C-ABI callee marshals BOTH words, so a callback that is
// not the last argument shifts the next C argument into the wrong register —
// silently. A callback has no C representation (a bound method is not a C
// function pointer), so passing one to a C-ABI function is now a hard error.
// Use `pointer` for a C function pointer. A C-ABI callee here is a bodyless
// variadic; a DWARF C import is the other form.
i32 ctake(callback cb i32(i32 x), i32 next, ...);
i32 main(void) { return 0; }
