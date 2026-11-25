//xtc-flags: expect=sema-error
// A string literal passed for an integer parameter is refused like the
// initialiser (#669).
// Refused: a string literal is a pointer, not a 'i32'

i32 twice(i32 n) { return n * 2; }

i32 main(void)
    {
    return twice("7");
    }
